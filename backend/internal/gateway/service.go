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
	"github.com/kenkomu/sokoni/backend/internal/money"
	"github.com/kenkomu/sokoni/backend/internal/store"
	"github.com/kenkomu/sokoni/backend/internal/userop"
	"github.com/kenkomu/sokoni/backend/internal/venue"
)

// Chain is the slice of a chain client the gateway reads through.
type Chain interface {
	Call(ctx context.Context, to string, data string) ([]byte, error)
	Code(ctx context.Context, address string) ([]byte, error)
	Balance(ctx context.Context, address string) (*big.Int, error)
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

// MarketData is the slice of store.Store the gateway reads market data
// through. *store.Store satisfies this structurally, and left nil (no
// DATABASE_URL configured) the market-data endpoints answer with
// KindUpstream rather than the gateway refusing to start — the same
// no-DB laptop mode Accounts already falls back to.
type MarketData interface {
	ListMarkets(ctx context.Context) ([]store.Market, error)
	MarketBySymbol(ctx context.Context, symbol string) (store.Market, bool, error)
	Candles(ctx context.Context, symbol string, intervalS, limit int) ([]store.Candle, error)
	RecentTrades(ctx context.Context, symbol string, limit int) ([]store.Trade, error)
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

// DefaultGas values are measured, not guessed: run against real Monad testnet
// through Pimlico on 2026-09-14 via cmd/onboard (see its longer note). The
// bundler rejected 200_000 preVerificationGas (needed 1,113,093 for a
// deploying account with a full WebAuthn signature) and 100 gwei maxFeePerGas
// (needed >=152.5 gwei at the time). Gas price drifts with the market — these
// are a safe floor with headroom, not permanent. Re-measure if
// eth_sendUserOperation starts rejecting on either again.
func DefaultGas() GasLimits {
	return GasLimits{
		Verification:           big.NewInt(600_000),
		VerificationWithDeploy: big.NewInt(1_500_000),
		Call:                   big.NewInt(400_000),
		PreVerification:        big.NewInt(1_400_000),
		MaxPriorityFee:         big.NewInt(3e9),
		MaxFee:                 big.NewInt(200e9),
	}
}

type Config struct {
	EntryPoint common.Address
	Factory    common.Address
	// MeraFactory is the Option 2 path's factory — a plain
	// SimpleAccountFactory, unmodified (see
	// contracts/script/DeployMeraAccountFactory.s.sol). Zero value disables
	// the /v1/mera/* endpoints rather than the gateway refusing to start,
	// the same graceful-degradation pattern Markets already uses.
	MeraFactory common.Address
	ChainID     *big.Int
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
	// MeraAccounts is nil in the same "feature not configured" sense as
	// Markets when MeraFactory is unset — RegisterMera/PrepareMera/
	// SubmitMera answer KindUpstream rather than the gateway refusing to
	// start.
	MeraAccounts MeraAccounts
	Ops          PendingOps
	Markets      MarketData
	Log          *slog.Logger
	Now          func() time.Time
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

// MeraAccountView is AccountView's Option 2 counterpart: the account is
// identified by its owner address rather than a WebAuthn credential id,
// because there is no separate credential — the address *is* the identity.
type MeraAccountView struct {
	Owner    string `json:"owner"`
	Address  string `json:"address"`
	Deployed bool   `json:"deployed"`
}

// Intent is what the phone asks for. Never calldata: the phone does not
// ABI-encode, and an endpoint that sponsored arbitrary calldata would be a
// general-purpose free gas tap.
//
// Two shapes share this one struct rather than each getting its own type,
// because both go through the same prepare/submit envelope and the JSON is
// simpler with one flat object than a tagged union: kind="transfer" uses
// Token/To/Amount; kind="trade" uses Market/Side/Amount. Amount always means
// "base units of whichever asset is being spent" — wei of the token for a
// transfer, wei of the base asset for a sell, wei of the quote asset for a
// buy — the phone computes it the same way either time (Money.parse against
// the relevant asset's own decimals), never a human-typed number.
type Intent struct {
	Kind   string `json:"kind"`
	Token  string `json:"token"`
	To     string `json:"to"`
	Amount string `json:"amount"` // base units, as a decimal string — never a float
	Market string `json:"market"`
	Side   string `json:"side"` // "buy" | "sell"
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

// candleIntervalS is the default when a request omits ?interval, and
// candleIntervalsS every bucket size store.ApplyBlocks actually populates
// (internal/store's candleIntervalsS) — kept in sync by hand since gateway
// does not import that private var.
const candleIntervalS = 60

var candleIntervalsS = map[int]bool{60: true, 300: true, 3600: true, 86400: true}

type MarketView struct {
	Symbol     string `json:"symbol"`
	BaseToken  string `json:"baseToken"`
	QuoteToken string `json:"quoteToken"`
	BaseDec    int32  `json:"baseDecimals"`
	QuoteDec   int32  `json:"quoteDecimals"`
	TickSize   string `json:"tickSize"`
	MinQty     string `json:"minQty"`
}

type MarketsView struct {
	Markets []MarketView `json:"markets"`
}

type CandleView struct {
	BucketTS   time.Time `json:"bucketTs"`
	Open       string    `json:"open"`
	High       string    `json:"high"`
	Low        string    `json:"low"`
	Close      string    `json:"close"`
	Volume     string    `json:"volume"`
	TradeCount int       `json:"tradeCount"`
}

type CandlesView struct {
	Candles []CandleView `json:"candles"`
}

type TradeView struct {
	FillID      int64  `json:"fillId"`
	Side        string `json:"side"`
	Px          string `json:"px"`
	Qty         string `json:"qty"`
	BlockNumber int64  `json:"blockNumber"`
	TxHash      string `json:"txHash"`
}

type TradesView struct {
	Trades []TradeView `json:"trades"`
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

	callData, err := s.buildCallData(ctx, in, cred.Address)
	if err != nil {
		return nil, err
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

// buildCallData turns a validated Intent into the calldata Prepare/PrepareMera
// put in a UserOperation, dispatching on Kind -- the one place either caller
// needs to know both intent shapes exist.
func (s *Service) buildCallData(ctx context.Context, in Intent, accountAddr common.Address) ([]byte, error) {
	switch in.Kind {
	case "transfer":
		return s.buildTransferCallData(ctx, in, accountAddr)
	case "trade":
		return s.buildTradeCallData(ctx, in, accountAddr)
	default:
		return nil, fail(KindInvalid, "unsupported_intent",
			fmt.Sprintf("%q is not something the gateway can do yet; \"transfer\" and \"trade\" are supported", in.Kind), nil)
	}
}

func (s *Service) buildTransferCallData(ctx context.Context, in Intent, accountAddr common.Address) ([]byte, error) {
	token, to, amount, err := s.validateIntent(in)
	if err != nil {
		return nil, err
	}

	// Refuse to sponsor a transfer that is certain to revert. A reverted
	// execution still costs the paymaster its gas, so without this anyone could
	// create empty accounts and drain the deposit one failed transfer at a time.
	balance, err := s.balanceOf(ctx, token.Address, accountAddr)
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
	return callData, nil
}

func (s *Service) validateIntent(in Intent) (Token, common.Address, *big.Int, error) {
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

// buildTradeCallData encodes a market buy/sell on Kuru. The security gate
// here is different from buildTransferCallData's SPONSORED_TOKENS allowlist:
// there is no separate token allowlist for trading, because the asset
// addresses come from our own `markets` row (found via MarketBySymbol, which
// only ever returns enabled=true), never from the request -- the allowlist
// *is* the enabled markets table.
//
// minAmountOut is always 0 for now: no on-chain slippage protection. A thin
// book can hand a market order back far less than its spot price implies.
// Tracked as a known gap (see CLAUDE.md), not silently assumed safe --
// closing it means a live bestBidAsk() read here before every trade.
func (s *Service) buildTradeCallData(ctx context.Context, in Intent, accountAddr common.Address) ([]byte, error) {
	if s.d.Markets == nil {
		return nil, s.noMarketData()
	}
	if in.Side != "buy" && in.Side != "sell" {
		return nil, fail(KindInvalid, "bad_side", `side must be "buy" or "sell"`, nil)
	}
	if in.Market == "" {
		return nil, fail(KindInvalid, "bad_market", "market must be a symbol, e.g. \"MON-USDC\"", nil)
	}
	amount, ok := parseAmount(in.Amount)
	if !ok {
		return nil, fail(KindInvalid, "bad_amount",
			"amount must be a positive whole number of base units, written as a string", nil)
	}

	m, found, err := s.d.Markets.MarketBySymbol(ctx, in.Market)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read the market", err)
	}
	if !found {
		return nil, fail(KindNotFound, "market_not_found", "no such market", nil)
	}
	if len(m.VenueRef) != 20 {
		return nil, fail(KindInvalid, "market_not_tradable", "this market has no order book configured", nil)
	}
	venueRef := common.BytesToAddress(m.VenueRef)
	baseToken := common.BytesToAddress(m.BaseToken)
	quoteToken := common.BytesToAddress(m.QuoteToken)
	minAmountOut := new(big.Int) // see doc comment above

	var asset common.Address
	var inner []byte

	if in.Side == "sell" {
		asset = baseToken
		sizeRaw, actualWei := venue.SizeRaw(amount, m.SizePrecision, m.BaseDec)
		if sizeRaw.Sign() == 0 {
			return nil, fail(KindInvalid, "bad_amount",
				"amount is below this market's smallest tradable size", nil)
		}
		if minQty, err := money.Parse(m.MinQty, m.BaseDec); err == nil && amount.Cmp(minQty.Units()) < 0 {
			return nil, fail(KindInvalid, "below_min_size",
				fmt.Sprintf("this market's minimum order size is %s", m.MinQty), nil)
		}
		if inner, err = venue.EncodePlaceAndExecuteMarketSell(sizeRaw, minAmountOut, false, false); err != nil {
			return nil, fail(KindInvalid, "encode", "could not encode the sell order", err)
		}
		amount = actualWei // the exact wei the contract will actually pull -- see SizeRaw's doc
	} else {
		asset = quoteToken
		quoteRaw, actualWei := venue.QuoteAmountRaw(amount, m.PricePrecision, m.QuoteDec)
		if quoteRaw.Sign() == 0 {
			return nil, fail(KindInvalid, "bad_amount",
				"amount is below this market's smallest tradable size", nil)
		}
		if inner, err = venue.EncodePlaceAndExecuteMarketBuy(quoteRaw, minAmountOut, false, false); err != nil {
			return nil, fail(KindInvalid, "encode", "could not encode the buy order", err)
		}
		amount = actualWei
	}

	native := asset == (common.Address{})
	var balance *big.Int
	if native {
		balance, err = s.d.Chain.Balance(ctx, accountAddr.Hex())
	} else {
		balance, err = s.balanceOf(ctx, asset, accountAddr)
	}
	if err != nil {
		return nil, err
	}
	if balance.Cmp(amount) < 0 {
		return nil, fail(KindInvalid, "insufficient_balance", fmt.Sprintf(
			"not enough of the %s asset — the account holds %s base units and this order needs %s; deposit or reduce the amount",
			map[bool]string{true: "sell", false: "buy"}[in.Side == "sell"], balance, amount), nil)
	}

	if native {
		callData, err := account.EncodeExecute(venueRef, amount, inner)
		if err != nil {
			return nil, fail(KindInvalid, "encode", "could not encode the call", err)
		}
		return callData, nil
	}

	// An ERC-20 leg (the token being sold, or the quote token being spent on
	// a buy) needs an approve before Kuru's transferFrom -- batched into the
	// same UserOperation as the trade itself, or the approval would be a
	// second, separately-signed step.
	approveCall, err := venue.EncodeApprove(venueRef, amount)
	if err != nil {
		return nil, fail(KindInvalid, "encode", "could not encode the approval", err)
	}
	callData, err := account.EncodeExecuteBatch(
		[]common.Address{asset, venueRef},
		[]*big.Int{new(big.Int), new(big.Int)},
		[][]byte{approveCall, inner},
	)
	if err != nil {
		return nil, fail(KindInvalid, "encode", "could not encode the call", err)
	}
	return callData, nil
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

// -------------------------------------------------------------- mera (Option 2)
//
// The ECDSA-owner path: PrepareMera/SubmitMera mirror Prepare/Submit exactly
// in shape (same two-round-trip contract, same "never rebuild on submit"
// rule), differing only in how the account is addressed and how its
// signature is checked. RegisterMera mirrors Register the same way.

func (s *Service) meraEnabled() error {
	if s.d.MeraAccounts == nil || s.cfg.MeraFactory == (common.Address{}) {
		return fail(KindUpstream, "mera_not_configured",
			"the Mera account path is not configured on this gateway", nil)
	}
	return nil
}

// RegisterMera records the smart account a Mera-derived owner key controls.
// Unlike Register, there is nothing to validate about the key itself — any
// non-zero address is a legitimate ECDSA public key; a passkey's PRF output
// deriving a bad one is not something this endpoint could detect anyway.
func (s *Service) RegisterMera(ctx context.Context, owner common.Address) (*MeraAccountView, error) {
	if err := s.meraEnabled(); err != nil {
		return nil, err
	}
	if owner == (common.Address{}) {
		return nil, fail(KindInvalid, "bad_owner", "owner must be a non-zero address", nil)
	}

	existing, found, err := s.d.MeraAccounts.Get(ctx, owner)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read mera accounts", err)
	}

	address := existing.Address
	if !found {
		if address, err = s.meraCounterfactual(ctx, owner); err != nil {
			return nil, err
		}
		if err := s.d.MeraAccounts.Put(ctx, MeraCredential{
			Owner: owner, Address: address, CreatedAt: s.d.Now(),
		}); err != nil {
			return nil, fail(KindUpstream, "store", "could not save the account", err)
		}
	}

	deployed, err := s.deployed(ctx, address)
	if err != nil {
		return nil, err
	}
	return &MeraAccountView{Owner: owner.Hex(), Address: address.Hex(), Deployed: deployed}, nil
}

// PrepareMera builds, sponsors and stores an operation for a Mera-owned
// account. Reuses the same PendingOps store as Prepare — an operation id is
// an operation id regardless of which account type will sign it — with the
// owner's hex address standing in for the WebAuthn credential id that field
// normally carries.
func (s *Service) PrepareMera(ctx context.Context, owner common.Address, in Intent) (*PreparedView, error) {
	if err := s.meraEnabled(); err != nil {
		return nil, err
	}
	cred, found, err := s.d.MeraAccounts.Get(ctx, owner)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read mera accounts", err)
	}
	if !found {
		return nil, fail(KindNotFound, "unknown_owner", "register this owner before sending anything", nil)
	}

	callData, err := s.buildCallData(ctx, in, cred.Address)
	if err != nil {
		return nil, err
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
		op.InitCode, err = account.InitCodeMera(s.cfg.MeraFactory, owner, big.NewInt(accountSalt))
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
		ID: id, CredentialID: owner.Hex(), Op: op, UserOpHash: hash, ExpiresAt: expires,
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

// SubmitMera accepts a 65-byte ECDSA signature (r, s, v — exactly what
// web3dart's Credentials.signPersonalMessage-style signers already produce)
// over the userOpHash, in place of Submit's WebAuthn assertion.
func (s *Service) SubmitMera(ctx context.Context, opID string, owner common.Address, sig []byte) (*SubmittedView, error) {
	if err := s.meraEnabled(); err != nil {
		return nil, err
	}
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
	ownerHex := owner.Hex()
	if ownerHex != "" && ownerHex != p.CredentialID {
		return nil, fail(KindInvalid, "wrong_owner",
			"signed with a different key than the one this operation was prepared for", nil)
	}

	cred, found, err := s.d.MeraAccounts.Get(ctx, owner)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read mera accounts", err)
	}
	if !found {
		return nil, fail(KindNotFound, "unknown_owner", "the owner for this operation is no longer registered", nil)
	}

	if err := account.VerifyMeraSignature(p.UserOpHash, sig, owner); err != nil {
		return nil, fail(KindInvalid, "bad_signature", meraSignatureMessage(err), err)
	}

	encoded, err := account.EncodeMeraSignature(sig)
	if err != nil {
		return nil, fail(KindInvalid, "bad_signature", "could not encode the signature", err)
	}
	op := *p.Op
	op.Signature = encoded

	sent, err := s.d.Bundler.SendUserOperation(ctx, &op)
	if err != nil {
		return nil, fail(KindUpstream, "bundler", "the bundler did not accept the operation", err)
	}
	if sent != p.UserOpHash {
		s.d.Log.Error("bundler userOpHash differs from ours — encoding drift",
			"op", opID, "ours", p.UserOpHash, "bundler", sent, "owner", cred.Owner)
	}

	if err := s.d.Ops.MarkSubmitted(ctx, opID, sent, s.d.Now()); err != nil {
		return nil, fail(KindUpstream, "store", "sent, but could not record it", err)
	}
	return &SubmittedView{OpID: opID, UserOpHash: sent.Hex(), Status: StatusSubmitted}, nil
}

func meraSignatureMessage(err error) string {
	switch {
	case errors.Is(err, account.ErrMeraSignatureLength):
		return "the signature must be exactly 65 bytes (r, s, v)"
	case errors.Is(err, account.ErrMeraBadSignature):
		return "the signature does not recover to this account's owner address"
	default:
		return "the signature is malformed"
	}
}

func (s *Service) meraCounterfactual(ctx context.Context, owner common.Address) (common.Address, error) {
	data, err := account.EncodeGetMeraAddress(owner, big.NewInt(accountSalt))
	if err != nil {
		return common.Address{}, fail(KindInvalid, "encode", "could not encode the address lookup", err)
	}
	out, err := s.d.Chain.Call(ctx, s.cfg.MeraFactory.Hex(), account.Hex(data))
	if err != nil {
		return common.Address{}, fail(KindUpstream, "chain", "could not ask the factory for the account address", err)
	}
	if len(out) != 32 {
		return common.Address{}, fail(KindUpstream, "chain",
			fmt.Sprintf("factory at %s returned %d bytes; is it deployed on this chain?", s.cfg.MeraFactory, len(out)), nil)
	}
	return common.BytesToAddress(out[12:]), nil
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

// ------------------------------------------------------------------ market data

// noMarketData is the error every market-data method returns when Deps.Markets
// is nil — no DATABASE_URL configured, the same laptop-friendly fallback
// Accounts already has, except there is no in-memory equivalent for read
// queries over an indexer-populated table, so this is a hard 502 rather than
// a degraded mode.
func (s *Service) noMarketData() error {
	return fail(KindUpstream, "no_market_data", "market data is not available: this gateway has no database configured", nil)
}

func (s *Service) ListMarkets(ctx context.Context) (*MarketsView, error) {
	if s.d.Markets == nil {
		return nil, s.noMarketData()
	}
	markets, err := s.d.Markets.ListMarkets(ctx)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read markets", err)
	}
	out := &MarketsView{Markets: make([]MarketView, 0, len(markets))}
	for _, m := range markets {
		out.Markets = append(out.Markets, MarketView{
			Symbol:     m.Symbol,
			BaseToken:  common.BytesToAddress(m.BaseToken).Hex(),
			QuoteToken: common.BytesToAddress(m.QuoteToken).Hex(),
			BaseDec:    m.BaseDec,
			QuoteDec:   m.QuoteDec,
			TickSize:   m.TickSize,
			MinQty:     m.MinQty,
		})
	}
	return out, nil
}

func (s *Service) Candles(ctx context.Context, symbol string, intervalS, limit int) (*CandlesView, error) {
	if s.d.Markets == nil {
		return nil, s.noMarketData()
	}
	if _, found, err := s.marketBySymbol(ctx, symbol); err != nil {
		return nil, err
	} else if !found {
		return nil, fail(KindNotFound, "market_not_found", "no such market", nil)
	}
	// Only the intervals store.ApplyBlocks actually populates exist as rows
	// at all — reject anything else rather than silently returning an empty
	// or wrong-bucket-size result, which a chart would render as if it were
	// what was asked for.
	if !candleIntervalsS[intervalS] {
		return nil, fail(KindInvalid, "unsupported_interval",
			"interval must be one of 60, 300, 3600, 86400 seconds", nil)
	}

	candles, err := s.d.Markets.Candles(ctx, symbol, intervalS, limit)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read candles", err)
	}
	out := &CandlesView{Candles: make([]CandleView, 0, len(candles))}
	for _, c := range candles {
		out.Candles = append(out.Candles, CandleView{
			BucketTS: c.BucketTS.UTC(), Open: c.Open, High: c.High, Low: c.Low,
			Close: c.Close, Volume: c.Volume, TradeCount: c.TradeCount,
		})
	}
	return out, nil
}

func (s *Service) RecentTrades(ctx context.Context, symbol string, limit int) (*TradesView, error) {
	if s.d.Markets == nil {
		return nil, s.noMarketData()
	}
	if _, found, err := s.marketBySymbol(ctx, symbol); err != nil {
		return nil, err
	} else if !found {
		return nil, fail(KindNotFound, "market_not_found", "no such market", nil)
	}

	trades, err := s.d.Markets.RecentTrades(ctx, symbol, limit)
	if err != nil {
		return nil, fail(KindUpstream, "store", "could not read trades", err)
	}
	out := &TradesView{Trades: make([]TradeView, 0, len(trades))}
	for _, t := range trades {
		out.Trades = append(out.Trades, TradeView{
			FillID: t.FillID, Side: t.Side, Px: t.Px, Qty: t.Qty,
			BlockNumber: t.BlockNumber, TxHash: "0x" + hex.EncodeToString(t.TxHash),
		})
	}
	return out, nil
}

func (s *Service) marketBySymbol(ctx context.Context, symbol string) (store.Market, bool, error) {
	m, found, err := s.d.Markets.MarketBySymbol(ctx, symbol)
	if err != nil {
		return store.Market{}, false, fail(KindUpstream, "store", "could not read markets", err)
	}
	return m, found, nil
}
