// Package gateway is the phone's only door onto the chain.
//
// The phone holds a passkey and nothing else. It cannot build a user operation,
// ABI-encode a call, or talk to a bundler — deliberately (the client/server
// split in CLAUDE.md). So every operation takes two round trips:
//
//	prepare  the phone states an intent; we build the operation, sponsor it,
//	         and hand back its userOpHash as a WebAuthn challenge
//	submit   the phone returns the assertion; we verify it, encode it into the
//	         signature field, and send the operation to the bundler
//
// Between the two, the prepared operation is held here byte for byte. It must
// never be rebuilt on submit: the nonce, the gas limits and the sponsorship
// window are all inside the hash the user just signed, and rebuilding any of
// them would make that signature worthless.
package gateway

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"time"
	"unicode"

	"github.com/ethereum/go-ethereum/common"

	"github.com/kenkomu/sokoni/backend/internal/account"
	"github.com/kenkomu/sokoni/backend/internal/bundler"
	"github.com/kenkomu/sokoni/backend/internal/userop"
)

// Chain is the slice of a chain client the gateway reads through.
type Chain interface {
	Call(ctx context.Context, to string, data string) ([]byte, error)
	Code(ctx context.Context, address string) ([]byte, error)
}

// Bundler is the slice of a bundler client the gateway submits through.
type Bundler interface {
	SendUserOperation(ctx context.Context, op *userop.UserOperation) (common.Hash, error)
	GetUserOperationReceipt(ctx context.Context, hash common.Hash) (*bundler.Receipt, error)
}

// Sponsor issues paymaster approvals. paymaster.Sponsor satisfies it.
type Sponsor interface {
	Approve(op *userop.UserOperation, validUntil, validAfter uint64, maxCost *big.Int) ([]byte, error)
	MaxCost(op *userop.UserOperation) *big.Int
}

// Token is an ERC-20 the paymaster will sponsor transfers of.
type Token struct {
	Address  common.Address
	Symbol   string
	Decimals int32
}

// GasLimits are hardcoded rather than estimated per operation. Monad charges on
// the gas limit, not the gas used, so an estimate buys nothing at runtime — and
// estimating a sponsored operation is circular, since the approval commits to
// the gas being estimated. Tune these from real receipts, not guesses.
type GasLimits struct {
	// Verification for an account that already exists: the WebAuthn check and
	// the P-256 precompile.
	Verification *big.Int
	// Verification for a first operation, which also deploys the account.
	VerificationWithDeploy *big.Int
	Call                   *big.Int
	PreVerification        *big.Int
	MaxPriorityFee         *big.Int
	MaxFee                 *big.Int
}

func DefaultGas() GasLimits {
	return GasLimits{
		Verification:           big.NewInt(600_000),
		VerificationWithDeploy: big.NewInt(1_500_000),
		Call:                   big.NewInt(400_000),
		PreVerification:        big.NewInt(200_000),
		MaxPriorityFee:         big.NewInt(1e9),
		MaxFee:                 big.NewInt(100e9),
	}
}

type Config struct {
	EntryPoint common.Address
	Factory    common.Address
	ChainID    *big.Int
	// sha256 of the relying-party id every credential must be bound to.
	RPIDHash [32]byte
	// The only tokens the paymaster will pay to move. Without an allowlist the
	// paymaster is a free gas tap for any contract call anyone can dream up.
	Tokens []Token
	Gas    GasLimits
	// How long a prepared operation stays signable. Long enough for a biometric
	// prompt and a hesitant thumb; short enough that a forgotten one is dead.
	OpTTL time.Duration
	// How long the paymaster approval outlives the signing window, so an
	// operation submitted at the last second still has time to land.
	LandingMargin time.Duration
}

// Deps are the gateway's collaborators. Now is injectable so expiry can be
// tested without sleeping.
type Deps struct {
	Chain    Chain
	Bundler  Bundler
	Sponsor  Sponsor
	Accounts Accounts
	Ops      PendingOps
	Log      *slog.Logger
	Now      func() time.Time
}

type Service struct {
	cfg    Config
	d      Deps
	tokens map[common.Address]Token
}

// accountSalt is fixed at 0: one passkey, one account. The factory salt commits
// to the owner set, so the same passkey deterministically recovers the same
// address on any device — which is the recovery story, so do not make it vary.
const accountSalt = 0

func NewService(cfg Config, d Deps) *Service {
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.Log == nil {
		d.Log = slog.Default()
	}
	if cfg.OpTTL == 0 {
		cfg.OpTTL = 5 * time.Minute
	}
	if cfg.LandingMargin == 0 {
		cfg.LandingMargin = 10 * time.Minute
	}
	tokens := make(map[common.Address]Token, len(cfg.Tokens))
	for _, t := range cfg.Tokens {
		tokens[t.Address] = t
	}
	return &Service{cfg: cfg, d: d, tokens: tokens}
}

// ------------------------------------------------------------------ errors

// Kind says which way a failure should be reported. The HTTP layer maps it to a
// status code; nothing below it knows HTTP exists.
type Kind int

const (
	KindInvalid Kind = iota + 1
	KindNotFound
	KindExpired
	KindConflict
	KindUpstream
)

// Error carries a stable machine code and a message written for a person. The
// message names the way out where there is one — "not enough USDC, deposit or
// reduce the amount", never "risk check 4 failed".
type Error struct {
	Kind    Kind
	Code    string
	Message string
	Err     error
}

func (e *Error) Error() string {
	if e.Err != nil {
		return e.Message + ": " + e.Err.Error()
	}
	return e.Message
}

func (e *Error) Unwrap() error { return e.Err }

func fail(kind Kind, code, msg string, err error) error {
	return &Error{Kind: kind, Code: code, Message: msg, Err: err}
}

// ------------------------------------------------------------------ views

type TokenView struct {
	Address  string `json:"address"`
	Symbol   string `json:"symbol"`
	Decimals int32  `json:"decimals"`
}

type ConfigView struct {
	ChainID    uint64      `json:"chainId"`
	EntryPoint string      `json:"entryPoint"`
	Tokens     []TokenView `json:"sponsoredTokens"`
}

type AccountView struct {
	CredentialID string `json:"credentialId"`
	Address      string `json:"address"`
	Deployed     bool   `json:"deployed"`
}

// Intent is what the phone asks for. Never calldata: the phone does not
// ABI-encode, and an endpoint that sponsored arbitrary calldata would be a
// general-purpose free gas tap.
type Intent struct {
	Kind   string `json:"kind"`
	Token  string `json:"token"`
	To     string `json:"to"`
	Amount string `json:"amount"` // base units, as a decimal string — never a float
}

type PreparedView struct {
	OpID string `json:"opId"`
	// The userOpHash. The phone signs these 32 bytes as its WebAuthn challenge.
	Challenge      string    `json:"challenge"`
	Sender         string    `json:"sender"`
	DeploysAccount bool      `json:"deploysAccount"`
	ExpiresAt      time.Time `json:"expiresAt"`
}

type SubmittedView struct {
	OpID       string `json:"opId"`
	UserOpHash string `json:"userOpHash"`
	Status     string `json:"status"`
}

// Status values, in the order an operation moves through them.
const (
	StatusPrepared  = "prepared"
	StatusSubmitted = "submitted"
	StatusLanded    = "landed"
	StatusReverted  = "reverted"
	StatusExpired   = "expired"
)

type StatusView struct {
	OpID        string `json:"opId"`
	Status      string `json:"status"`
	UserOpHash  string `json:"userOpHash,omitempty"`
	TxHash      string `json:"txHash,omitempty"`
	BlockNumber uint64 `json:"blockNumber,omitempty"`
	Reason      string `json:"reason,omitempty"`
}

// ------------------------------------------------------------------ config

func (s *Service) Config() ConfigView {
	out := ConfigView{
		ChainID:    s.cfg.ChainID.Uint64(),
		EntryPoint: s.cfg.EntryPoint.Hex(),
		Tokens:     make([]TokenView, 0, len(s.cfg.Tokens)),
	}
	for _, t := range s.cfg.Tokens {
		out.Tokens = append(out.Tokens, TokenView{Address: t.Address.Hex(), Symbol: t.Symbol, Decimals: t.Decimals})
	}
	return out
}

// ---------------------------------------------------------------- register

// Register binds a passkey to its account address. Idempotent: the same
// credential and key return the same answer however often they are sent, which
// is what a phone retrying on a flaky connection needs.
func (s *Service) Register(ctx context.Context, credentialID string, owner account.Passkey) (*AccountView, error) {
	if err := validCredentialID(credentialID); err != nil {
		return nil, err
	}
	if _, err := owner.PublicKey(); err != nil {
		return nil, fail(KindInvalid, "bad_public_key",
			"that public key is not a P-256 point, so no signature could ever authorise its account", err)
	}

	existing, found, err := s.d.Accounts.Get(ctx, credentialID)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read accounts", err)
	}
	if found && !samePasskey(existing.Owner, owner) {
		return nil, fail(KindConflict, "credential_key_mismatch",
			"this credential is already registered with a different public key", nil)
	}

	address := existing.Address
	if !found {
		if address, err = s.counterfactual(ctx, owner); err != nil {
			return nil, err
		}
		if err := s.d.Accounts.Put(ctx, Credential{
			ID: credentialID, Owner: owner, Address: address, CreatedAt: s.d.Now(),
		}); err != nil {
			return nil, fail(KindUpstream, "store", "could not save the account", err)
		}
	}

	deployed, err := s.deployed(ctx, address)
	if err != nil {
		return nil, err
	}
	return &AccountView{CredentialID: credentialID, Address: address.Hex(), Deployed: deployed}, nil
}

func validCredentialID(id string) error {
	if id == "" {
		return fail(KindInvalid, "bad_credential_id", "credentialId is required", nil)
	}
	if len(id) > 512 {
		return fail(KindInvalid, "bad_credential_id", "credentialId is implausibly long", nil)
	}
	for _, r := range id {
		if unicode.IsControl(r) || unicode.IsSpace(r) {
			return fail(KindInvalid, "bad_credential_id", "credentialId contains whitespace or control characters", nil)
		}
	}
	return nil
}

func samePasskey(a, b account.Passkey) bool {
	return a.X != nil && a.Y != nil && b.X != nil && b.Y != nil &&
		a.X.Cmp(b.X) == 0 && a.Y.Cmp(b.Y) == 0
}

// ----------------------------------------------------------------- prepare

// Prepare builds, sponsors and stores an operation, and returns the challenge
// the phone must sign.
func (s *Service) Prepare(ctx context.Context, credentialID string, in Intent) (*PreparedView, error) {
	cred, found, err := s.d.Accounts.Get(ctx, credentialID)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read accounts", err)
	}
	if !found {
		return nil, fail(KindNotFound, "unknown_credential", "register this passkey before sending anything", nil)
	}

	token, to, amount, err := s.validateIntent(in)
	if err != nil {
		return nil, err
	}

	// Refuse to sponsor a transfer that is certain to revert. A reverted
	// execution still costs the paymaster its gas, so without this anyone could
	// create empty accounts and drain the deposit one failed transfer at a time.
	balance, err := s.balanceOf(ctx, token.Address, cred.Address)
	if err != nil {
		return nil, err
	}
	if balance.Cmp(amount) < 0 {
		return nil, fail(KindInvalid, "insufficient_balance", fmt.Sprintf(
			"not enough %s — the account holds %s base units and this sends %s; deposit or reduce the amount",
			token.Symbol, balance, amount), nil)
	}

	inner, err := account.EncodeERC20Transfer(to, amount)
	if err != nil {
		return nil, fail(KindInvalid, "bad_amount", err.Error(), nil)
	}
	callData, err := account.EncodeExecute(token.Address, new(big.Int), inner)
	if err != nil {
		return nil, fail(KindInvalid, "encode", "could not encode the call", err)
	}

	deployed, err := s.deployed(ctx, cred.Address)
	if err != nil {
		return nil, err
	}

	gas := s.cfg.Gas
	op := &userop.UserOperation{
		Sender:               cred.Address,
		CallData:             callData,
		VerificationGasLimit: gas.Verification,
		CallGasLimit:         gas.Call,
		PreVerificationGas:   gas.PreVerification,
		MaxPriorityFeePerGas: gas.MaxPriorityFee,
		MaxFeePerGas:         gas.MaxFee,
	}
	if !deployed {
		// initCode only on the first operation; the EntryPoint rejects it (AA10)
		// for an account that already exists.
		op.InitCode, err = account.InitCode(s.cfg.Factory, s.cfg.RPIDHash,
			[]account.Passkey{cred.Owner}, big.NewInt(accountSalt))
		if err != nil {
			return nil, fail(KindInvalid, "encode", "could not encode account deployment", err)
		}
		op.VerificationGasLimit = gas.VerificationWithDeploy
	}

	if op.Nonce, err = s.nonce(ctx, cred.Address); err != nil {
		return nil, err
	}

	now := s.d.Now()
	expires := now.Add(s.cfg.OpTTL)
	validUntil := uint64(expires.Add(s.cfg.LandingMargin).Unix())

	// Sponsor BEFORE hashing: the userOpHash covers paymasterAndData.
	pmd, err := s.d.Sponsor.Approve(op, validUntil, 0, s.d.Sponsor.MaxCost(op))
	if err != nil {
		return nil, fail(KindUpstream, "sponsor", "could not sponsor this operation", err)
	}
	op.PaymasterAndData = pmd

	hash, err := op.Hash(s.cfg.EntryPoint, s.cfg.ChainID)
	if err != nil {
		return nil, fail(KindInvalid, "hash", "could not hash the operation", err)
	}

	id, err := newOpID()
	if err != nil {
		return nil, fail(KindUpstream, "id", "could not mint an operation id", err)
	}
	if err := s.d.Ops.Put(ctx, Pending{
		ID: id, CredentialID: credentialID, Op: op, UserOpHash: hash, ExpiresAt: expires,
	}); err != nil {
		return nil, fail(KindUpstream, "store", "could not save the operation", err)
	}

	return &PreparedView{
		OpID:           id,
		Challenge:      hash.Hex(),
		Sender:         cred.Address.Hex(),
		DeploysAccount: !deployed,
		ExpiresAt:      expires.UTC(),
	}, nil
}

func (s *Service) validateIntent(in Intent) (Token, common.Address, *big.Int, error) {
	if in.Kind != "transfer" {
		return Token{}, common.Address{}, nil, fail(KindInvalid, "unsupported_intent",
			fmt.Sprintf("%q is not something the gateway can do yet; only \"transfer\" is supported", in.Kind), nil)
	}
	if !common.IsHexAddress(in.Token) {
		return Token{}, common.Address{}, nil, fail(KindInvalid, "bad_token", "token must be a 0x address", nil)
	}
	token, ok := s.tokens[common.HexToAddress(in.Token)]
	if !ok {
		return Token{}, common.Address{}, nil, fail(KindInvalid, "token_not_sponsored",
			"that token is not one the gateway sponsors; GET /v1/config lists the ones it does", nil)
	}
	if !common.IsHexAddress(in.To) || common.HexToAddress(in.To) == (common.Address{}) {
		return Token{}, common.Address{}, nil, fail(KindInvalid, "bad_recipient", "recipient must be a non-zero 0x address", nil)
	}
	amount, ok := parseAmount(in.Amount)
	if !ok {
		return Token{}, common.Address{}, nil, fail(KindInvalid, "bad_amount",
			"amount must be a positive whole number of base units, written as a string", nil)
	}
	return token, common.HexToAddress(in.To), amount, nil
}

// parseAmount accepts only plain decimal digits. No sign, no exponent, no
// decimal point: base units are integers, and anything else is a client that
// has been doing float arithmetic somewhere it should not.
func parseAmount(s string) (*big.Int, bool) {
	if s == "" || len(s) > 78 || strings.TrimLeft(s, "0123456789") != "" {
		return nil, false
	}
	v, ok := new(big.Int).SetString(s, 10)
	if !ok || v.Sign() <= 0 || v.BitLen() > 256 {
		return nil, false
	}
	return v, true
}

// ------------------------------------------------------------------ submit

// Submit verifies the assertion against the stored operation and sends it.
//
// Idempotent: a second submit of the same operation returns the first result
// without sending again. Two taps on a flaky connection must not become two
// bundler submissions — though if they race past this check, the EntryPoint's
// nonce still guarantees the operation executes at most once.
func (s *Service) Submit(ctx context.Context, opID string, credentialID string, a account.Assertion) (*SubmittedView, error) {
	p, found, err := s.d.Ops.Get(ctx, opID)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read the operation", err)
	}
	if !found {
		return nil, fail(KindNotFound, "unknown_op", "no such operation; prepare a new one", nil)
	}
	if p.Submitted() {
		return &SubmittedView{OpID: opID, UserOpHash: p.BundlerHash.Hex(), Status: StatusSubmitted}, nil
	}
	if s.d.Now().After(p.ExpiresAt) {
		return nil, fail(KindExpired, "op_expired", "this operation expired before it was signed; prepare a new one", nil)
	}
	if credentialID != "" && credentialID != p.CredentialID {
		return nil, fail(KindInvalid, "wrong_credential",
			"signed with a different passkey than the one this operation was prepared for", nil)
	}

	cred, found, err := s.d.Accounts.Get(ctx, p.CredentialID)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read accounts", err)
	}
	if !found {
		return nil, fail(KindNotFound, "unknown_credential", "the passkey for this operation is no longer registered", nil)
	}

	// The account passes abi.encode(userOpHash) as the challenge: the 32 bytes.
	if err := account.VerifyAssertion(p.UserOpHash[:], s.cfg.RPIDHash, true, a, cred.Owner); err != nil {
		return nil, fail(KindInvalid, "bad_assertion", assertionMessage(err), err)
	}

	sig, err := account.EncodeSignature(0, a)
	if err != nil {
		return nil, fail(KindInvalid, "bad_assertion", "could not encode the assertion", err)
	}
	// Copy, then attach the signature. Every other byte is exactly what was
	// hashed at prepare time.
	op := *p.Op
	op.Signature = sig

	sent, err := s.d.Bundler.SendUserOperation(ctx, &op)
	if err != nil {
		return nil, fail(KindUpstream, "bundler", "the bundler did not accept the operation", err)
	}
	if sent != p.UserOpHash {
		// The bundler hashes independently. If it disagrees with us, our
		// encoding has drifted from the EntryPoint's and every signature we hand
		// out is for the wrong bytes. The golden vector exists to prevent this.
		s.d.Log.Error("bundler userOpHash differs from ours — encoding drift",
			"op", opID, "ours", p.UserOpHash, "bundler", sent)
	}

	if err := s.d.Ops.MarkSubmitted(ctx, opID, sent, s.d.Now()); err != nil {
		return nil, fail(KindUpstream, "store", "sent, but could not record it", err)
	}
	return &SubmittedView{OpID: opID, UserOpHash: sent.Hex(), Status: StatusSubmitted}, nil
}

// assertionMessage explains a verification failure in terms a developer can
// act on. These are client bugs, not user errors, so precision beats polish.
func assertionMessage(err error) string {
	switch {
	case errors.Is(err, account.ErrWrongChallenge):
		return "the passkey signed a different challenge than this operation's"
	case errors.Is(err, account.ErrHighS):
		return "the signature was not normalised to low-s before submitting"
	case errors.Is(err, account.ErrUserNotVerified):
		return "the authenticator did not verify the user; a biometric or PIN is required"
	case errors.Is(err, account.ErrWrongRelyingParty):
		return "the passkey belongs to a different app or domain"
	case errors.Is(err, account.ErrBadSignature):
		return "the signature does not verify against this account's passkey"
	default:
		return "the assertion is malformed"
	}
}

// ------------------------------------------------------------------ status

func (s *Service) Status(ctx context.Context, opID string) (*StatusView, error) {
	p, found, err := s.d.Ops.Get(ctx, opID)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read the operation", err)
	}
	if !found {
		return nil, fail(KindNotFound, "unknown_op", "no such operation", nil)
	}

	if !p.Submitted() {
		status := StatusPrepared
		if s.d.Now().After(p.ExpiresAt) {
			status = StatusExpired
		}
		return &StatusView{OpID: opID, Status: status}, nil
	}

	view := &StatusView{OpID: opID, Status: StatusSubmitted, UserOpHash: p.BundlerHash.Hex()}
	receipt, err := s.d.Bundler.GetUserOperationReceipt(ctx, p.BundlerHash)
	if err != nil {
		return nil, fail(KindUpstream, "bundler", "could not ask the bundler for a receipt", err)
	}
	if receipt == nil {
		return view, nil
	}
	view.TxHash = receipt.TxHash.Hex()
	view.BlockNumber = receipt.BlockNumber
	if receipt.Success {
		view.Status = StatusLanded
	} else {
		view.Status = StatusReverted
		view.Reason = receipt.Reason
	}
	return view, nil
}

// ------------------------------------------------------------------ chain reads

func (s *Service) counterfactual(ctx context.Context, owner account.Passkey) (common.Address, error) {
	data, err := account.EncodeGetAddress(s.cfg.RPIDHash, []account.Passkey{owner}, big.NewInt(accountSalt))
	if err != nil {
		return common.Address{}, fail(KindInvalid, "encode", "could not encode the address lookup", err)
	}
	out, err := s.d.Chain.Call(ctx, s.cfg.Factory.Hex(), account.Hex(data))
	if err != nil {
		return common.Address{}, fail(KindUpstream, "chain", "could not ask the factory for the account address", err)
	}
	if len(out) != 32 {
		return common.Address{}, fail(KindUpstream, "chain",
			fmt.Sprintf("factory at %s returned %d bytes; is it deployed on this chain?", s.cfg.Factory, len(out)), nil)
	}
	return common.BytesToAddress(out[12:]), nil
}

func (s *Service) deployed(ctx context.Context, addr common.Address) (bool, error) {
	code, err := s.d.Chain.Code(ctx, addr.Hex())
	if err != nil {
		return false, fail(KindUpstream, "chain", "could not check whether the account is deployed", err)
	}
	return len(code) > 0, nil
}

func (s *Service) nonce(ctx context.Context, sender common.Address) (*big.Int, error) {
	data, err := account.EncodeGetNonce(sender, nil)
	if err != nil {
		return nil, fail(KindInvalid, "encode", "could not encode the nonce lookup", err)
	}
	out, err := s.d.Chain.Call(ctx, s.cfg.EntryPoint.Hex(), account.Hex(data))
	if err != nil {
		return nil, fail(KindUpstream, "chain", "could not read the account nonce", err)
	}
	if len(out) != 32 {
		return nil, fail(KindUpstream, "chain",
			fmt.Sprintf("EntryPoint returned %d bytes for getNonce", len(out)), nil)
	}
	return new(big.Int).SetBytes(out), nil
}

func (s *Service) balanceOf(ctx context.Context, token, holder common.Address) (*big.Int, error) {
	data, err := account.EncodeBalanceOf(holder)
	if err != nil {
		return nil, fail(KindInvalid, "encode", "could not encode the balance lookup", err)
	}
	out, err := s.d.Chain.Call(ctx, token.Hex(), account.Hex(data))
	if err != nil {
		return nil, fail(KindUpstream, "chain", "could not read the token balance", err)
	}
	if len(out) != 32 {
		return nil, fail(KindUpstream, "chain",
			fmt.Sprintf("token at %s returned %d bytes for balanceOf; is it an ERC-20 on this chain?", token, len(out)), nil)
	}
	return new(big.Int).SetBytes(out), nil
}

// newOpID is random rather than a Snowflake. An op id lets its holder poll the
// operation's status, which names the sender and the transaction; a sortable id
// would let anyone walk everyone else's.
func newOpID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return "op_" + hex.EncodeToString(b[:]), nil
}
