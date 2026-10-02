package gateway

import (
	"bytes"
	"context"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/kenkomu/sokoni/backend/internal/account"
	"github.com/kenkomu/sokoni/backend/internal/bundler"
	"github.com/kenkomu/sokoni/backend/internal/paymaster"
	"github.com/kenkomu/sokoni/backend/internal/store"
	"github.com/kenkomu/sokoni/backend/internal/userop"
)

var (
	testEntryPoint = common.HexToAddress("0x0000000071727De22E5E9d8BAf0edAc6f37da032")
	testFactory    = common.HexToAddress("0x000000000000000000000000000000000000FAC7")
	testPaymaster  = common.HexToAddress("0x000000000000000000000000000000000000BEEF")
	testToken      = common.HexToAddress("0x00000000000000000000000000000000000070CE")
	testAccount    = common.HexToAddress("0x000000000000000000000000000000000000ACC7")
	testRecipient  = common.HexToAddress("0x0000000000000000000000000000000000C0FFEE")
	testChainID    = big.NewInt(10143)
	testRPIDHash   = sha256.Sum256([]byte("sokoni.app"))
)

const cred = "dGVzdC1jcmVkZW50aWFs"

func sel(sig string) string { return "0x" + hex.EncodeToString(crypto.Keccak256([]byte(sig))[:4]) }

var (
	getAddressSel = sel("getAddress(bytes32,(uint256,uint256)[],uint256)")
	getNonceSel   = sel("getNonce(address,uint192)")
	balanceOfSel  = sel("balanceOf(address)")
)

func word(b []byte) []byte {
	out := make([]byte, 32)
	copy(out[32-len(b):], b)
	return out
}

// ---------------------------------------------------------------- fakes

// fakeChain answers exactly the three reads the gateway makes, and refuses
// anything else — including the right address with the wrong selector.
type fakeChain struct {
	mu      sync.Mutex
	nonce   *big.Int
	balance *big.Int
	code    map[common.Address][]byte
}

func (f *fakeChain) Call(_ context.Context, to, data string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(data) < 10 {
		return nil, fmt.Errorf("calldata too short: %q", data)
	}
	s := data[:10]
	switch common.HexToAddress(to) {
	case testFactory:
		// createAccount takes identical arguments; calling it by mistake would
		// deploy rather than predict.
		if s != getAddressSel {
			return nil, fmt.Errorf("factory called with %s, want getAddress", s)
		}
		return word(testAccount.Bytes()), nil
	case testEntryPoint:
		if s != getNonceSel {
			return nil, fmt.Errorf("EntryPoint called with %s, want getNonce", s)
		}
		return word(f.nonce.Bytes()), nil
	case testToken:
		if s != balanceOfSel {
			return nil, fmt.Errorf("token called with %s, want balanceOf", s)
		}
		return word(f.balance.Bytes()), nil
	}
	return nil, fmt.Errorf("unexpected eth_call to %s", to)
}

func (f *fakeChain) Code(_ context.Context, address string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.code[common.HexToAddress(address)], nil
}

// Balance answers the same fixed native balance for every address -- trade
// tests on a native-base market exercise this, but never more than one
// account per test, so per-address state has never been needed.
func (f *fakeChain) Balance(_ context.Context, _ string) (*big.Int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.balance == nil {
		return big.NewInt(0), nil
	}
	return f.balance, nil
}

func (f *fakeChain) set(fn func(*fakeChain)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

type fakeBundler struct {
	mu      sync.Mutex
	sent    []userop.UserOperation
	receipt *bundler.Receipt
	err     error
}

func (f *fakeBundler) SendUserOperation(_ context.Context, op *userop.UserOperation) (common.Hash, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return common.Hash{}, f.err
	}
	f.sent = append(f.sent, *op)
	// A real bundler hashes the operation itself, independently of us.
	return op.Hash(testEntryPoint, testChainID)
}

func (f *fakeBundler) GetUserOperationReceipt(_ context.Context, _ common.Hash) (*bundler.Receipt, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.receipt, nil
}

func (f *fakeBundler) setReceipt(r *bundler.Receipt) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.receipt = r
}

func (f *fakeBundler) setErr(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.err = err
}

func (f *fakeBundler) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sent)
}

func (f *fakeBundler) only(t *testing.T) userop.UserOperation {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.sent) != 1 {
		t.Fatalf("bundler received %d operations, want exactly 1", len(f.sent))
	}
	return f.sent[0]
}

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// ---------------------------------------------------------------- rig

type rig struct {
	svc     *Service
	chain   *fakeChain
	bundler *fakeBundler
	clock   *clock
	markets *fakeMarketData
	hub     *Hub
}

// fakeMarketData is a MarketData a test can seed directly, so gateway tests
// never need a real Postgres -- that coverage lives in
// internal/store/reads_test.go against the real schema.
type fakeMarketData struct {
	mu      sync.Mutex
	markets []store.Market
	candles map[string][]store.Candle // key: symbol
	trades  map[string][]store.Trade  // key: symbol
}

func newFakeMarketData() *fakeMarketData {
	return &fakeMarketData{candles: map[string][]store.Candle{}, trades: map[string][]store.Trade{}}
}

func (f *fakeMarketData) ListMarkets(context.Context) ([]store.Market, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]store.Market{}, f.markets...), nil
}

func (f *fakeMarketData) MarketBySymbol(_ context.Context, symbol string) (store.Market, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, m := range f.markets {
		if m.Symbol == symbol {
			return m, true, nil
		}
	}
	return store.Market{}, false, nil
}

func (f *fakeMarketData) Candles(_ context.Context, symbol string, _, limit int) ([]store.Candle, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	rows := f.candles[symbol]
	if len(rows) > limit {
		rows = rows[len(rows)-limit:]
	}
	return append([]store.Candle{}, rows...), nil
}

func (f *fakeMarketData) RecentTrades(_ context.Context, symbol string, limit int) ([]store.Trade, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	rows := f.trades[symbol]
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return append([]store.Trade{}, rows...), nil
}

func quietLog() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// A real Sponsor, not a fake: approvals are pure crypto, and faking them would
// hide exactly the encoding bugs the gateway exists to avoid.
func newRig(t *testing.T) *rig {
	t.Helper()
	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	sp, err := paymaster.NewSponsorWithKey(testPaymaster, testChainID, key)
	if err != nil {
		t.Fatal(err)
	}
	ch := &fakeChain{nonce: big.NewInt(0), balance: big.NewInt(1_000_000), code: map[common.Address][]byte{}}
	b := &fakeBundler{}
	c := &clock{t: time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)}
	md := newFakeMarketData()
	svc := NewService(Config{
		EntryPoint: testEntryPoint,
		Factory:    testFactory,
		ChainID:    testChainID,
		RPIDHash:   testRPIDHash,
		Tokens:     []Token{{Address: testToken, Symbol: "TST", Decimals: 6}},
		Gas:        DefaultGas(),
		OpTTL:      5 * time.Minute,
	}, Deps{
		Chain:    ch,
		Bundler:  b,
		Sponsor:  sp,
		Accounts: NewMemoryAccounts(),
		Ops:      NewMemoryOps(time.Hour, c.Now),
		Markets:  md,
		Log:      quietLog(),
		Now:      c.Now,
	})
	hub := NewHub(md, quietLog())
	return &rig{svc: svc, chain: ch, bundler: b, clock: c, markets: md, hub: hub}
}

func (r *rig) pending(t *testing.T, id string) Pending {
	t.Helper()
	p, ok, err := r.svc.d.Ops.Get(context.Background(), id)
	if err != nil || !ok {
		t.Fatalf("pending %s: found=%v err=%v", id, ok, err)
	}
	return p
}

func transfer(amount string) Intent {
	return Intent{Kind: "transfer", Token: testToken.Hex(), To: testRecipient.Hex(), Amount: amount}
}

// gPasskey is the P-256 generator: a valid point nobody holds the key for.
// Good for every test that registers but never signs.
func gPasskey() account.Passkey {
	p := elliptic.P256().Params()
	return account.Passkey{X: new(big.Int).Set(p.Gx), Y: new(big.Int).Set(p.Gy)}
}

func errKind(err error) Kind {
	var e *Error
	if errors.As(err, &e) {
		return e.Kind
	}
	return 0
}

func errCode(err error) string {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

// ---------------------------------------------------------------- the test passkey

// Signing uses script/gen_webauthn_vector.py — the same pure-Python P-256 key
// the Foundry tests sign with — so the gateway's verification runs over a real
// assertion of a real prepared userOpHash, not a fixture that happens to fit.
const signerScript = "../../../contracts/script/gen_webauthn_vector.py"

func requirePython(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not available; the test passkey is a Python P-256 signer")
	}
}

func runSigner(t *testing.T, args ...string) map[string]json.RawMessage {
	t.Helper()
	out, err := exec.Command("python3", append([]string{signerScript}, args...)...).Output()
	if err != nil {
		t.Fatalf("signer %v: %v", args, err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatalf("decode signer output: %v", err)
	}
	return m
}

// rawBig reads an integer the signer may emit either as a JSON number or as a
// quoted hex or decimal string — and never through a float64, which would
// destroy a 256-bit value.
func rawBig(t *testing.T, raw json.RawMessage) *big.Int {
	t.Helper()
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		if strings.HasPrefix(s, "0x") {
			return new(big.Int).SetBytes(common.FromHex(s))
		}
		v, ok := new(big.Int).SetString(s, 10)
		if !ok {
			t.Fatalf("not an integer: %q", s)
		}
		return v
	}
	v, ok := new(big.Int).SetString(string(raw), 10)
	if !ok {
		t.Fatalf("not an integer: %s", raw)
	}
	return v
}

func rawString(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatalf("not a string: %s", raw)
	}
	return s
}

func testPasskey(t *testing.T) account.Passkey {
	t.Helper()
	m := runSigner(t, "--pubkey")
	return account.Passkey{X: rawBig(t, m["x"]), Y: rawBig(t, m["y"])}
}

func signWithTestPasskey(t *testing.T, challenge common.Hash) account.Assertion {
	t.Helper()
	m := runSigner(t, "--sign", challenge.Hex())
	return account.Assertion{
		AuthenticatorData: common.FromHex(rawString(t, m["authenticatorData"])),
		ClientDataJSON:    rawString(t, m["clientDataJSON"]),
		ChallengeIndex:    rawBig(t, m["challengeIndex"]).Uint64(),
		TypeIndex:         rawBig(t, m["typeIndex"]).Uint64(),
		R:                 rawBig(t, m["r"]),
		S:                 rawBig(t, m["s"]),
	}
}

// ---------------------------------------------------------------- tests

// Balances reads live balanceOf for every sponsored token — one token here,
// same as the rest of this file's Config, so the fake's single-token Call
// branch (see fakeChain.Call's testToken case) is enough to pin it.
func TestBalancesReadsEverySponsoredToken(t *testing.T) {
	r := newRig(t)
	r.chain.balance = big.NewInt(42_000_000)

	got, err := r.svc.Balances(context.Background(), testAccount)
	if err != nil {
		t.Fatalf("Balances: %v", err)
	}
	if got.Address != testAccount.Hex() {
		t.Fatalf("address = %s, want %s", got.Address, testAccount.Hex())
	}
	if len(got.Balances) != 1 {
		t.Fatalf("len(Balances) = %d, want 1", len(got.Balances))
	}
	b := got.Balances[0]
	if b.Token.Symbol != "TST" || b.Token.Address != testToken.Hex() || b.Token.Decimals != 6 {
		t.Fatalf("token = %+v, want TST/%s/6", b.Token, testToken.Hex())
	}
	if b.Amount != "42000000" {
		t.Fatalf("amount = %s, want 42000000", b.Amount)
	}
}

// A person's portfolio was never actually limited to whichever token the
// paymaster happens to sponsor gas for -- a MON-USDC trade leaves MON in the
// account whether or not MON itself is sponsored.
func TestBalancesIncludesEveryMarketToken(t *testing.T) {
	r := newRig(t)
	r.chain.balance = big.NewInt(7_000_000)
	r.markets.markets = []store.Market{nativeMarket()}

	got, err := r.svc.Balances(context.Background(), testAccount)
	if err != nil {
		t.Fatalf("Balances: %v", err)
	}
	// nativeMarket's quote is testToken, already sponsored -- the market
	// token list must dedupe against it, not double it, so this is exactly
	// {TST, native MON}, not three entries.
	if len(got.Balances) != 2 {
		t.Fatalf("len(Balances) = %d, want 2: %+v", len(got.Balances), got.Balances)
	}
	var sawTST, sawMON bool
	for _, b := range got.Balances {
		switch {
		case b.Token.Address == testToken.Hex():
			sawTST = true
			if b.Token.Symbol != "TST" {
				t.Errorf("sponsored token symbol = %s, want TST (sponsored config wins over the market's MON-USDC quote name)", b.Token.Symbol)
			}
		case b.Token.Address == (common.Address{}).Hex():
			sawMON = true
			if b.Token.Symbol != "MON" || b.Token.Decimals != 18 {
				t.Errorf("native token = %+v, want MON/18", b.Token)
			}
			if b.Amount != "7000000" {
				t.Errorf("native amount = %s, want 7000000", b.Amount)
			}
		}
	}
	if !sawTST || !sawMON {
		t.Fatalf("missing an expected token: %+v", got.Balances)
	}
}

// The whole Phase 1 loop, minus the phone and the chain: register, prepare,
// sign the challenge, submit, watch it land.
func TestFullLoopWithTheTestPasskey(t *testing.T) {
	requirePython(t)
	r := newRig(t)
	ctx := context.Background()

	acct, err := r.svc.Register(ctx, cred, testPasskey(t))
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if acct.Address != testAccount.Hex() || acct.Deployed {
		t.Fatalf("register = %+v, want undeployed %s", acct, testAccount.Hex())
	}

	prep, err := r.svc.Prepare(ctx, cred, transfer("250000"))
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if !prep.DeploysAccount {
		t.Error("the first operation must deploy the account")
	}

	p := r.pending(t, prep.OpID)
	if len(p.Op.InitCode) < 20 || common.BytesToAddress(p.Op.InitCode[:20]) != testFactory {
		t.Errorf("initCode must lead with the factory: %x", p.Op.InitCode)
	}
	if len(p.Op.PaymasterAndData) != paymaster.DataLength {
		t.Errorf("paymasterAndData is %d bytes, want %d", len(p.Op.PaymasterAndData), paymaster.DataLength)
	}
	if p.Op.VerificationGasLimit.Cmp(DefaultGas().VerificationWithDeploy) != 0 {
		t.Errorf("a deploying operation needs the deploy verification limit, got %s", p.Op.VerificationGasLimit)
	}
	hash, err := p.Op.Hash(testEntryPoint, testChainID)
	if err != nil {
		t.Fatal(err)
	}
	if prep.Challenge != hash.Hex() {
		t.Fatalf("challenge %s is not the userOpHash %s", prep.Challenge, hash.Hex())
	}

	assertion := signWithTestPasskey(t, hash)
	sub, err := r.svc.Submit(ctx, prep.OpID, cred, assertion)
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	if sub.UserOpHash != prep.Challenge {
		t.Errorf("submitted hash %s, want %s", sub.UserOpHash, prep.Challenge)
	}

	sent := r.bundler.only(t)
	wantSig, err := account.EncodeSignature(0, assertion)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(sent.Signature, wantSig) {
		t.Error("the bundler must receive the assertion encoded exactly as the account decodes it")
	}
	if h, _ := sent.Hash(testEntryPoint, testChainID); h != hash {
		t.Error("the submitted operation must hash to the challenge the user signed")
	}

	st, err := r.svc.Status(ctx, prep.OpID)
	if err != nil || st.Status != StatusSubmitted {
		t.Fatalf("status = %+v, %v; want submitted", st, err)
	}

	r.bundler.setReceipt(&bundler.Receipt{Success: true, TxHash: common.Hash{31: 1}, BlockNumber: 42})
	st, err = r.svc.Status(ctx, prep.OpID)
	if err != nil || st.Status != StatusLanded || st.BlockNumber != 42 {
		t.Fatalf("status = %+v, %v; want landed at 42", st, err)
	}
}

// The reason verification happens here at all: a bad assertion must cost one
// 400, not a validation failure charged to the paymaster's reputation.
func TestSubmitRefusesAnAssertionOverAnotherChallenge(t *testing.T) {
	requirePython(t)
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, testPasskey(t)); err != nil {
		t.Fatal(err)
	}
	prep, err := r.svc.Prepare(ctx, cred, transfer("1"))
	if err != nil {
		t.Fatal(err)
	}

	wrong := signWithTestPasskey(t, crypto.Keccak256Hash([]byte("some other operation")))
	_, err = r.svc.Submit(ctx, prep.OpID, cred, wrong)
	if errCode(err) != "bad_assertion" {
		t.Fatalf("got %v, want bad_assertion", err)
	}
	if n := r.bundler.count(); n != 0 {
		t.Fatalf("a failed verification must never reach the bundler; it received %d", n)
	}
}

// Two taps on a flaky connection must not become two submissions.
func TestSubmitIsIdempotent(t *testing.T) {
	requirePython(t)
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, testPasskey(t)); err != nil {
		t.Fatal(err)
	}
	prep, err := r.svc.Prepare(ctx, cred, transfer("1"))
	if err != nil {
		t.Fatal(err)
	}
	a := signWithTestPasskey(t, common.HexToHash(prep.Challenge))

	first, err := r.svc.Submit(ctx, prep.OpID, cred, a)
	if err != nil {
		t.Fatal(err)
	}
	second, err := r.svc.Submit(ctx, prep.OpID, cred, a)
	if err != nil {
		t.Fatal(err)
	}
	if first.UserOpHash != second.UserOpHash {
		t.Errorf("repeat submit changed the answer: %s vs %s", first.UserOpHash, second.UserOpHash)
	}
	if n := r.bundler.count(); n != 1 {
		t.Fatalf("bundler received %d submissions, want 1", n)
	}
}

func TestExpiredOperationCannotBeSubmitted(t *testing.T) {
	requirePython(t)
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, testPasskey(t)); err != nil {
		t.Fatal(err)
	}
	prep, err := r.svc.Prepare(ctx, cred, transfer("1"))
	if err != nil {
		t.Fatal(err)
	}
	a := signWithTestPasskey(t, common.HexToHash(prep.Challenge))

	r.clock.Advance(5*time.Minute + time.Second)
	if _, err := r.svc.Submit(ctx, prep.OpID, cred, a); errKind(err) != KindExpired {
		t.Fatalf("got %v, want KindExpired", err)
	}
	st, err := r.svc.Status(ctx, prep.OpID)
	if err != nil || st.Status != StatusExpired {
		t.Fatalf("status = %+v, %v; want expired", st, err)
	}
}

// The property the whole two-step design rests on: whatever changes on chain
// between prepare and submit, the operation sent is the one the user signed.
func TestPreparedOperationIsNotRebuiltOnSubmit(t *testing.T) {
	requirePython(t)
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, testPasskey(t)); err != nil {
		t.Fatal(err)
	}
	prep, err := r.svc.Prepare(ctx, cred, transfer("1"))
	if err != nil {
		t.Fatal(err)
	}

	// The world moves on: the nonce advances and the account gets deployed.
	r.chain.set(func(f *fakeChain) {
		f.nonce = big.NewInt(99)
		f.code[testAccount] = []byte{0x60}
	})

	a := signWithTestPasskey(t, common.HexToHash(prep.Challenge))
	if _, err := r.svc.Submit(ctx, prep.OpID, cred, a); err != nil {
		t.Fatalf("submit: %v", err)
	}
	sent := r.bundler.only(t)
	if sent.Nonce.Sign() != 0 {
		t.Errorf("nonce was rebuilt to %s; it must stay what the user signed", sent.Nonce)
	}
	if len(sent.InitCode) == 0 {
		t.Error("initCode was dropped on submit; the signed operation carried it")
	}
	if h, _ := sent.Hash(testEntryPoint, testChainID); h.Hex() != prep.Challenge {
		t.Error("submitted operation no longer hashes to the signed challenge")
	}
}

// A bundler hiccup must leave the operation retryable, not stuck.
func TestBundlerFailureCanBeRetried(t *testing.T) {
	requirePython(t)
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, testPasskey(t)); err != nil {
		t.Fatal(err)
	}
	prep, err := r.svc.Prepare(ctx, cred, transfer("1"))
	if err != nil {
		t.Fatal(err)
	}
	a := signWithTestPasskey(t, common.HexToHash(prep.Challenge))

	r.bundler.setErr(errors.New("rpc error -32505: stake too low"))
	if _, err := r.svc.Submit(ctx, prep.OpID, cred, a); errKind(err) != KindUpstream {
		t.Fatalf("got %v, want KindUpstream", err)
	}
	if st, _ := r.svc.Status(ctx, prep.OpID); st.Status != StatusPrepared {
		t.Fatalf("a failed send must leave the op prepared, got %s", st.Status)
	}

	r.bundler.setErr(nil)
	if _, err := r.svc.Submit(ctx, prep.OpID, cred, a); err != nil {
		t.Fatalf("retry after the bundler recovered: %v", err)
	}
}

func TestSubmitRefusesAnotherCredential(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	prep, err := r.svc.Prepare(ctx, cred, transfer("1"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.svc.Submit(ctx, prep.OpID, "someone-else", account.Assertion{}); errCode(err) != "wrong_credential" {
		t.Fatalf("got %v, want wrong_credential", err)
	}
}

func TestPrepareRefusesATokenItDoesNotSponsor(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	in := transfer("1")
	in.Token = common.HexToAddress("0x00000000000000000000000000000000000BAD00").Hex()
	if _, err := r.svc.Prepare(ctx, cred, in); errCode(err) != "token_not_sponsored" {
		t.Fatalf("got %v, want token_not_sponsored", err)
	}
}

// A transfer that must revert still costs the paymaster its gas. Refusing it
// here is what stops empty accounts being used to drain the deposit.
func TestPrepareRefusesATransferThatWouldRevert(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	r.chain.set(func(f *fakeChain) { f.balance = big.NewInt(10) })

	_, err := r.svc.Prepare(ctx, cred, transfer("250000"))
	if errCode(err) != "insufficient_balance" {
		t.Fatalf("got %v, want insufficient_balance", err)
	}
	// The message names the way out, not the subsystem.
	if !strings.Contains(err.Error(), "deposit or reduce") {
		t.Errorf("message should tell the user what to do: %v", err)
	}
}

func TestPrepareRequiresRegistration(t *testing.T) {
	r := newRig(t)
	if _, err := r.svc.Prepare(context.Background(), cred, transfer("1")); errKind(err) != KindNotFound {
		t.Fatalf("got %v, want KindNotFound", err)
	}
}

func TestPrepareRefusesUnsupportedIntents(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	in := transfer("1")
	in.Kind = "swap"
	if _, err := r.svc.Prepare(ctx, cred, in); errCode(err) != "unsupported_intent" {
		t.Fatalf("got %v, want unsupported_intent", err)
	}
}

// ---------------------------------------------------------------- trade intents

var (
	testVenueRef = common.HexToAddress("0x000000000000000000000000000000000000B00C")
	executeSel   = sel("execute(address,uint256,bytes)")
	executeBatch = sel("executeBatch(address[],uint256[],bytes[])")
)

// nativeMarket sells the account's own native MON (base=zero address) for
// testToken (quote) -- the same shape as the real MON-USDC market.
func nativeMarket() store.Market {
	return store.Market{
		Symbol:         "MON-USDC",
		BaseToken:      common.Address{}.Bytes(),
		QuoteToken:     testToken.Bytes(),
		BaseDec:        18,
		QuoteDec:       6,
		Venue:          "kuru",
		VenueRef:       testVenueRef.Bytes(),
		MinQty:         "200",
		PricePrecision: 100_000_000,
		SizePrecision:  10_000_000_000,
	}
}

// erc20Market sells testToken as the base asset against a synthetic quote --
// the same shape as the real ETH-USDC/BTC-USDC markets, where selling needs
// an approve first.
func erc20Market() store.Market {
	return store.Market{
		Symbol:         "WETH-USDC",
		BaseToken:      testToken.Bytes(),
		QuoteToken:     common.HexToAddress("0x00000000000000000000000000000000000051AB").Bytes(),
		BaseDec:        18,
		QuoteDec:       6,
		Venue:          "kuru",
		VenueRef:       testVenueRef.Bytes(),
		MinQty:         "0.002",
		PricePrecision: 10_000,
		SizePrecision:  10_000_000_000,
	}
}

func trade(market, side, amount string) Intent {
	return Intent{Kind: "trade", Market: market, Side: side, Amount: amount}
}

func TestTradeSellNativeBaseEncodesASingleExecuteWithValue(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	r.markets.markets = []store.Market{nativeMarket()}
	// 1_000_000 wei (fakeChain's default balance) covers a tiny sell; use an
	// amount well under it but still above minSize (200 MON here would need
	// 2e20 wei, more than the fake's default balance, so raise it).
	r.chain.set(func(f *fakeChain) { f.balance = new(big.Int).Mul(big.NewInt(300), pow10(18)) })

	sellWei := new(big.Int).Mul(big.NewInt(200), pow10(18)) // the market's own minSize
	view, err := r.svc.Prepare(ctx, cred, trade("MON-USDC", "sell", sellWei.String()))
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	p := r.pending(t, view.OpID)
	if got := "0x" + hex.EncodeToString(p.Op.CallData[:4]); got != executeSel {
		t.Errorf("callData selector = %s, want execute (single call, native value attached)", got)
	}
}

func TestTradeSellERC20BaseEncodesExecuteBatchWithApprove(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	r.markets.markets = []store.Market{erc20Market()}
	r.chain.set(func(f *fakeChain) { f.balance = new(big.Int).Mul(big.NewInt(10), pow10(18)) })

	sellWei := new(big.Int).Div(pow10(18), big.NewInt(100)) // 0.01 WETH, above the 0.002 min
	view, err := r.svc.Prepare(ctx, cred, trade("WETH-USDC", "sell", sellWei.String()))
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	p := r.pending(t, view.OpID)
	if got := "0x" + hex.EncodeToString(p.Op.CallData[:4]); got != executeBatch {
		t.Errorf("callData selector = %s, want executeBatch (approve + sell)", got)
	}
}

func TestTradeBuyEncodesExecuteBatchWithApprove(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	m := nativeMarket() // quote is testToken regardless of which fixture
	r.markets.markets = []store.Market{m}
	r.chain.set(func(f *fakeChain) { f.balance = big.NewInt(50_000_000) }) // 50 USDC @ 6dp

	view, err := r.svc.Prepare(ctx, cred, trade("MON-USDC", "buy", "10000000")) // 10 USDC
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	p := r.pending(t, view.OpID)
	if got := "0x" + hex.EncodeToString(p.Op.CallData[:4]); got != executeBatch {
		t.Errorf("callData selector = %s, want executeBatch (approve + buy, quote is always ERC-20 here)", got)
	}
}

func TestTradeRefusesAnUnknownMarket(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	if _, err := r.svc.Prepare(ctx, cred, trade("NOPE-USDC", "sell", "1")); errCode(err) != "market_not_found" {
		t.Fatalf("got %v, want market_not_found", err)
	}
}

func TestTradeRefusesBelowMinSize(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	r.markets.markets = []store.Market{nativeMarket()}
	r.chain.set(func(f *fakeChain) { f.balance = new(big.Int).Mul(big.NewInt(300), pow10(18)) })

	tiny := pow10(18) // 1 MON, far below the market's 200 MON minSize
	if _, err := r.svc.Prepare(ctx, cred, trade("MON-USDC", "sell", tiny.String())); errCode(err) != "below_min_size" {
		t.Fatalf("got %v, want below_min_size", err)
	}
}

// A buy is sized in the quote asset, so unlike a sell (checked directly
// against MinQty above) it needs a recent trade price to translate "how
// much USDC" into "how much MON this implies" before MinQty even applies --
// this is the check that closed the BTC-USDC gap (a $6.57 buy silently
// reverted on-chain with TransferFailed() instead of a clean error, since
// the buy branch checked only quoteRaw.Sign() == 0).
func TestTradeBuyRefusesBelowMinSizeAtTheLastTradedPrice(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	m := nativeMarket() // MinQty 200 MON
	r.markets.markets = []store.Market{m}
	r.markets.trades["MON-USDC"] = []store.Trade{{Px: "0.5"}}                 // 0.5 USDC/MON
	r.chain.set(func(f *fakeChain) { f.balance = big.NewInt(1_000_000_000) }) // 1,000 USDC @ 6dp

	// 10 USDC / 0.5 USDC-per-MON = 20 MON, far below the 200 MON minimum.
	tooSmall := trade("MON-USDC", "buy", "10000000")
	if _, err := r.svc.Prepare(ctx, cred, tooSmall); errCode(err) != "below_min_size" {
		t.Fatalf("got %v, want below_min_size", err)
	}

	// 200 USDC / 0.5 USDC-per-MON = 400 MON, comfortably at/above minimum.
	enough := trade("MON-USDC", "buy", "200000000")
	if _, err := r.svc.Prepare(ctx, cred, enough); err != nil {
		t.Fatalf("Prepare with an adequate buy size: %v", err)
	}
}

func TestTradeRefusesInsufficientBalance(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	r.markets.markets = []store.Market{nativeMarket()}
	r.chain.set(func(f *fakeChain) { f.balance = big.NewInt(10) }) // far below 200 MON

	sellWei := new(big.Int).Mul(big.NewInt(200), pow10(18))
	if _, err := r.svc.Prepare(ctx, cred, trade("MON-USDC", "sell", sellWei.String())); errCode(err) != "insufficient_balance" {
		t.Fatalf("got %v, want insufficient_balance", err)
	}
}

func TestTradeRefusesABadSide(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	r.markets.markets = []store.Market{nativeMarket()}
	if _, err := r.svc.Prepare(ctx, cred, trade("MON-USDC", "hodl", "1")); errCode(err) != "bad_side" {
		t.Fatalf("got %v, want bad_side", err)
	}
}

func pow10(n int64) *big.Int { return new(big.Int).Exp(big.NewInt(10), big.NewInt(n), nil) }

func TestRegisterIsIdempotentButRefusesAKeySwap(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()

	a, err := r.svc.Register(ctx, cred, gPasskey())
	if err != nil {
		t.Fatal(err)
	}
	b, err := r.svc.Register(ctx, cred, gPasskey())
	if err != nil {
		t.Fatalf("re-registering the same key must succeed: %v", err)
	}
	if a.Address != b.Address {
		t.Errorf("same key, different addresses: %s vs %s", a.Address, b.Address)
	}

	// 2G: a different, equally valid point.
	x, y := elliptic.P256().ScalarBaseMult([]byte{2})
	if _, err := r.svc.Register(ctx, cred, account.Passkey{X: x, Y: y}); errKind(err) != KindConflict {
		t.Fatalf("rebinding a credential to another key must be refused, got %v", err)
	}
}

// An off-curve key yields a valid-looking address nobody can ever sign for.
func TestRegisterRefusesAnOffCurveKey(t *testing.T) {
	r := newRig(t)
	bad := account.Passkey{X: big.NewInt(1), Y: big.NewInt(1)}
	if _, err := r.svc.Register(context.Background(), cred, bad); errCode(err) != "bad_public_key" {
		t.Fatalf("got %v, want bad_public_key", err)
	}
}

func TestRegisterRefusesAMalformedCredentialID(t *testing.T) {
	r := newRig(t)
	for _, id := range []string{"", "has space", "tab\there", strings.Repeat("a", 513)} {
		if _, err := r.svc.Register(context.Background(), id, gPasskey()); errCode(err) != "bad_credential_id" {
			t.Errorf("id %q: got %v, want bad_credential_id", id, err)
		}
	}
}

// initCode on an existing account is rejected by the EntryPoint (AA10).
func TestDeployedAccountSendsNoInitCode(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	r.chain.set(func(f *fakeChain) { f.code[testAccount] = []byte{0x60} })
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	prep, err := r.svc.Prepare(ctx, cred, transfer("1"))
	if err != nil {
		t.Fatal(err)
	}
	if prep.DeploysAccount {
		t.Error("an existing account must not be deployed again")
	}
	p := r.pending(t, prep.OpID)
	if len(p.Op.InitCode) != 0 {
		t.Errorf("initCode must be empty for a deployed account: %x", p.Op.InitCode)
	}
	if p.Op.VerificationGasLimit.Cmp(DefaultGas().Verification) != 0 {
		t.Errorf("no deployment, so no deployment gas: got %s", p.Op.VerificationGasLimit)
	}
}

// The approval has to outlive the signing window, or an operation signed at
// the last second would be refused by the paymaster before it could land.
func TestSponsorshipOutlivesTheSigningWindow(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	if _, err := r.svc.Register(ctx, cred, gPasskey()); err != nil {
		t.Fatal(err)
	}
	prep, err := r.svc.Prepare(ctx, cred, transfer("1"))
	if err != nil {
		t.Fatal(err)
	}
	pmd := r.pending(t, prep.OpID).Op.PaymasterAndData
	validUntil := new(big.Int).SetBytes(pmd[52:58]).Int64()
	if validUntil <= prep.ExpiresAt.Unix() {
		t.Fatalf("approval expires at %d, before the signing window closes at %d", validUntil, prep.ExpiresAt.Unix())
	}
}

// fakeAssistant records the question and grounding it was actually called
// with, so a test can assert the service builds grounding text from real
// balances/activity rather than trusting internal/assistant's own (already
// tested against a live account) behaviour.
type fakeAssistant struct {
	gotQuestion, gotGrounding string
	answer                    string
	err                       error
}

func (f *fakeAssistant) Ask(_ context.Context, question, grounding string) (string, error) {
	f.gotQuestion, f.gotGrounding = question, grounding
	return f.answer, f.err
}

func TestAssistUnavailableWithoutAConfiguredAssistant(t *testing.T) {
	r := newRig(t)
	if _, err := r.svc.Assist(context.Background(), testAccount, "why did my trade fail?"); errCode(err) != "assistant_unavailable" {
		t.Fatalf("got %v, want assistant_unavailable", err)
	}
}

func TestAssistRefusesAnEmptyQuestion(t *testing.T) {
	r := newRig(t)
	r.svc.d.Assistant = &fakeAssistant{answer: "unused"}
	if _, err := r.svc.Assist(context.Background(), testAccount, "   "); errCode(err) != "empty_question" {
		t.Fatalf("got %v, want empty_question", err)
	}
}

func TestAssistGroundsTheQuestionInRealBalances(t *testing.T) {
	r := newRig(t)
	fa := &fakeAssistant{answer: "You hold 50 TST."}
	r.svc.d.Assistant = fa
	r.markets.markets = []store.Market{nativeMarket()}
	r.chain.set(func(f *fakeChain) { f.balance = big.NewInt(50_000_000) }) // 50 TST @ 6dp

	view, err := r.svc.Assist(context.Background(), testAccount, "how much do I hold?")
	if err != nil {
		t.Fatalf("Assist: %v", err)
	}
	if view.Answer != "You hold 50 TST." {
		t.Errorf("answer = %q, want the assistant's own text passed through unchanged", view.Answer)
	}
	if fa.gotQuestion != "how much do I hold?" {
		t.Errorf("question = %q", fa.gotQuestion)
	}
	if !strings.Contains(fa.gotGrounding, "50") || !strings.Contains(fa.gotGrounding, "TST") {
		t.Errorf("grounding = %q, want it to mention the real 50 TST balance", fa.gotGrounding)
	}
}

func TestParseAmount(t *testing.T) {
	for _, bad := range []string{"", "0", "000", "-1", "+1", "1.5", "1e6", " 1", "1 ", "0x10", strings.Repeat("9", 79)} {
		if _, ok := parseAmount(bad); ok {
			t.Errorf("%q must be refused", bad)
		}
	}
	for in, want := range map[string]int64{"1": 1, "250000": 250000, "007": 7} {
		got, ok := parseAmount(in)
		if !ok || got.Int64() != want {
			t.Errorf("%q = %v, %v; want %d", in, got, ok, want)
		}
	}
}
