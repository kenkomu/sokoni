package gateway

import (
	"encoding/json"
	"errors"
	"log/slog"
	"math/big"
	"net/http"
	"strconv"

	"github.com/ethereum/go-ethereum/common"

	"github.com/kenkomu/sokoni/backend/internal/account"
)

// maxBody bounds every request. The largest legitimate one is an assertion,
// which is well under a kilobyte.
const maxBody = 64 << 10

// NewHandler routes the gateway's HTTP API.
//
//	GET  /healthz
//	GET  /v1/config                        chain, EntryPoint, sponsored tokens
//	POST /v1/accounts                      register a passkey, learn its account address
//	POST /v1/ops                           prepare an operation, receive its challenge
//	POST /v1/ops/{id}/submit               return the signed assertion
//	GET  /v1/ops/{id}                      poll for the outcome
//	POST /v1/mera/accounts                 register a Mera-derived owner, learn its account address
//	POST /v1/mera/ops                      prepare an operation for a Mera-owned account
//	POST /v1/mera/ops/{id}/submit          return the signed ECDSA signature
//	GET  /v1/accounts/{address}/balances   every sponsored token's balanceOf, read live
//	GET  /v1/markets                       enabled markets
//	GET  /v1/markets/{symbol}/candles      candle history (interval query param, seconds)
//	GET  /v1/markets/{symbol}/trades       recent market-wide trades (limit query param)
//	GET  /v1/stream                        WebSocket: {"op":"sub","ch":[...]} subscribes
//
// hub may be nil (no DATABASE_URL configured, same as svc.d.Markets being nil)
// — /v1/stream then refuses the upgrade with a 503 rather than accepting
// connections it can never publish anything to.
func NewHandler(svc *Service, hub *Hub, log *slog.Logger) http.Handler {
	if log == nil {
		log = slog.Default()
	}
	h := &handler{svc: svc, hub: hub, log: log}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /v1/config", h.config)
	mux.HandleFunc("POST /v1/accounts", h.register)
	mux.HandleFunc("POST /v1/ops", h.prepare)
	mux.HandleFunc("POST /v1/ops/{id}/submit", h.submit)
	mux.HandleFunc("GET /v1/ops/{id}", h.status)
	mux.HandleFunc("POST /v1/mera/accounts", h.registerMera)
	mux.HandleFunc("POST /v1/mera/ops", h.prepareMera)
	mux.HandleFunc("POST /v1/mera/ops/{id}/submit", h.submitMera)
	mux.HandleFunc("GET /v1/accounts/{address}/balances", h.balances)
	mux.HandleFunc("GET /v1/markets", h.markets)
	mux.HandleFunc("GET /v1/markets/{symbol}/candles", h.candles)
	mux.HandleFunc("GET /v1/markets/{symbol}/trades", h.trades)
	mux.HandleFunc("GET /v1/stream", h.stream)
	return mux
}

type handler struct {
	svc *Service
	hub *Hub
	log *slog.Logger
}

type errorBody struct {
	Error   string `json:"error"`
	Message string `json:"message"`
	// Detail carries the upstream reason (a bundler's annotated rejection,
	// say). Invaluable while Phase 1 is being debugged on a device; tighten
	// before real users see it.
	Detail string `json:"detail,omitempty"`
}

func (h *handler) config(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, h.svc.Config())
}

func (h *handler) register(w http.ResponseWriter, r *http.Request) {
	var body struct {
		CredentialID string `json:"credentialId"`
		X            string `json:"x"`
		Y            string `json:"y"`
	}
	if !h.decode(w, r, &body) {
		return
	}
	x, okX := parseWord(body.X)
	y, okY := parseWord(body.Y)
	if !okX || !okY {
		h.fail(w, fail(KindInvalid, "bad_public_key", "x and y must be 0x-prefixed hex of at most 32 bytes", nil))
		return
	}
	view, err := h.svc.Register(r.Context(), body.CredentialID, account.Passkey{X: x, Y: y})
	h.respond(w, http.StatusCreated, view, err)
}

func (h *handler) prepare(w http.ResponseWriter, r *http.Request) {
	var body struct {
		CredentialID string `json:"credentialId"`
		Intent       Intent `json:"intent"`
	}
	if !h.decode(w, r, &body) {
		return
	}
	view, err := h.svc.Prepare(r.Context(), body.CredentialID, body.Intent)
	h.respond(w, http.StatusCreated, view, err)
}

// submit accepts exactly what PasskeyAssertion.toJson() emits on the phone, so
// the client sends its assertion as-is with no mapping layer to drift.
func (h *handler) submit(w http.ResponseWriter, r *http.Request) {
	var body struct {
		CredentialID      string `json:"credentialId"`
		AuthenticatorData string `json:"authenticatorData"`
		ClientDataJSON    string `json:"clientDataJSON"`
		ChallengeIndex    uint64 `json:"challengeIndex"`
		TypeIndex         uint64 `json:"typeIndex"`
		R                 string `json:"r"`
		S                 string `json:"s"`
	}
	if !h.decode(w, r, &body) {
		return
	}
	rr, okR := parseWord(body.R)
	ss, okS := parseWord(body.S)
	authData, okA := parseBytes(body.AuthenticatorData)
	if !okR || !okS || !okA {
		h.fail(w, fail(KindInvalid, "bad_assertion", "authenticatorData, r and s must be 0x-prefixed hex", nil))
		return
	}
	view, err := h.svc.Submit(r.Context(), r.PathValue("id"), body.CredentialID, account.Assertion{
		AuthenticatorData: authData,
		ClientDataJSON:    body.ClientDataJSON,
		ChallengeIndex:    body.ChallengeIndex,
		TypeIndex:         body.TypeIndex,
		R:                 rr,
		S:                 ss,
	})
	h.respond(w, http.StatusAccepted, view, err)
}

// ----------------------------------------------------------- mera (Option 2)

func (h *handler) registerMera(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Owner string `json:"owner"`
	}
	if !h.decode(w, r, &body) {
		return
	}
	if !common.IsHexAddress(body.Owner) {
		h.fail(w, fail(KindInvalid, "bad_owner", "owner must be a 0x address", nil))
		return
	}
	view, err := h.svc.RegisterMera(r.Context(), common.HexToAddress(body.Owner))
	h.respond(w, http.StatusCreated, view, err)
}

func (h *handler) prepareMera(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Owner  string `json:"owner"`
		Intent Intent `json:"intent"`
	}
	if !h.decode(w, r, &body) {
		return
	}
	if !common.IsHexAddress(body.Owner) {
		h.fail(w, fail(KindInvalid, "bad_owner", "owner must be a 0x address", nil))
		return
	}
	view, err := h.svc.PrepareMera(r.Context(), common.HexToAddress(body.Owner), body.Intent)
	h.respond(w, http.StatusCreated, view, err)
}

// submitMera accepts a 65-byte (r, s, v) signature as 0x-hex — exactly what
// most Ethereum signing libraries, including the Dart one the client uses,
// already produce, with no WebAuthn-shaped mapping layer needed.
func (h *handler) submitMera(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Owner     string `json:"owner"`
		Signature string `json:"signature"`
	}
	if !h.decode(w, r, &body) {
		return
	}
	if !common.IsHexAddress(body.Owner) {
		h.fail(w, fail(KindInvalid, "bad_owner", "owner must be a 0x address", nil))
		return
	}
	sig, okSig := parseBytes(body.Signature)
	if !okSig {
		h.fail(w, fail(KindInvalid, "bad_signature", "signature must be 0x-prefixed hex", nil))
		return
	}
	view, err := h.svc.SubmitMera(r.Context(), r.PathValue("id"), common.HexToAddress(body.Owner), sig)
	h.respond(w, http.StatusAccepted, view, err)
}

func (h *handler) status(w http.ResponseWriter, r *http.Request) {
	view, err := h.svc.Status(r.Context(), r.PathValue("id"))
	h.respond(w, http.StatusOK, view, err)
}

func (h *handler) balances(w http.ResponseWriter, r *http.Request) {
	addr := r.PathValue("address")
	if !common.IsHexAddress(addr) {
		h.fail(w, fail(KindInvalid, "bad_address", "address must be a 0x address", nil))
		return
	}
	view, err := h.svc.Balances(r.Context(), common.HexToAddress(addr))
	h.respond(w, http.StatusOK, view, err)
}

func (h *handler) markets(w http.ResponseWriter, r *http.Request) {
	view, err := h.svc.ListMarkets(r.Context())
	h.respond(w, http.StatusOK, view, err)
}

// defaultLimit/maxLimit bound every list query; parsing and clamping happens
// here, in the request-parsing layer, not in the Service, which takes only
// already-validated ints.
const (
	defaultLimit = 100
	maxLimit     = 500
)

func parseLimit(r *http.Request) (int, error) {
	s := r.URL.Query().Get("limit")
	if s == "" {
		return defaultLimit, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		return 0, fail(KindInvalid, "bad_query", "limit must be a positive integer", nil)
	}
	if n > maxLimit {
		n = maxLimit
	}
	return n, nil
}

func (h *handler) candles(w http.ResponseWriter, r *http.Request) {
	interval := candleIntervalS
	if s := r.URL.Query().Get("interval"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n <= 0 {
			h.fail(w, fail(KindInvalid, "bad_query", "interval must be a positive integer, in seconds", nil))
			return
		}
		interval = n
	}
	limit, err := parseLimit(r)
	if err != nil {
		h.fail(w, err)
		return
	}
	view, err := h.svc.Candles(r.Context(), r.PathValue("symbol"), interval, limit)
	h.respond(w, http.StatusOK, view, err)
}

func (h *handler) trades(w http.ResponseWriter, r *http.Request) {
	limit, err := parseLimit(r)
	if err != nil {
		h.fail(w, err)
		return
	}
	view, err := h.svc.RecentTrades(r.Context(), r.PathValue("symbol"), limit)
	h.respond(w, http.StatusOK, view, err)
}

// ---------------------------------------------------------------- plumbing

func (h *handler) decode(w http.ResponseWriter, r *http.Request, into any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	if err := json.NewDecoder(r.Body).Decode(into); err != nil {
		h.fail(w, fail(KindInvalid, "bad_json", "request body is not the JSON this endpoint expects", err))
		return false
	}
	return true
}

func (h *handler) respond(w http.ResponseWriter, status int, v any, err error) {
	if err != nil {
		h.fail(w, err)
		return
	}
	writeJSON(w, status, v)
}

func (h *handler) fail(w http.ResponseWriter, err error) {
	var e *Error
	if !errors.As(err, &e) {
		h.log.Error("unhandled gateway error", "err", err)
		writeJSON(w, http.StatusInternalServerError,
			errorBody{Error: "internal", Message: "something went wrong on our side"})
		return
	}
	body := errorBody{Error: e.Code, Message: e.Message}
	if e.Kind == KindUpstream {
		h.log.Warn("upstream failure", "code", e.Code, "err", e.Err)
		if e.Err != nil {
			body.Detail = e.Err.Error()
		}
	}
	writeJSON(w, statusFor(e.Kind), body)
}

func statusFor(k Kind) int {
	switch k {
	case KindInvalid:
		return http.StatusBadRequest
	case KindNotFound:
		return http.StatusNotFound
	case KindExpired:
		return http.StatusGone
	case KindConflict:
		return http.StatusConflict
	case KindUpstream:
		return http.StatusBadGateway
	default:
		return http.StatusInternalServerError
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// parseWord reads a 0x-hex integer of at most 32 bytes.
//
// Deliberately not hexutil.DecodeBig, which rejects leading zeros. The phone
// zero-pads every coordinate and scalar to 32 bytes — correctly — and a strict
// decoder would refuse roughly one key in 256 for no reason.
func parseWord(s string) (*big.Int, bool) {
	b, ok := parseBytes(s)
	if !ok || len(b) == 0 || len(b) > 32 {
		return nil, false
	}
	return new(big.Int).SetBytes(b), true
}

func parseBytes(s string) ([]byte, bool) {
	if len(s) < 2 || s[:2] != "0x" {
		return nil, false
	}
	if len(s)%2 != 0 {
		return nil, false
	}
	b := common.FromHex(s)
	// FromHex is lenient about junk; round-trip to make sure it was real hex.
	if common.Bytes2Hex(b) != toLowerHex(s[2:]) {
		return nil, false
	}
	return b, true
}

func toLowerHex(s string) string {
	out := []byte(s)
	for i, c := range out {
		if c >= 'A' && c <= 'F' {
			out[i] = c + ('a' - 'A')
		}
	}
	return string(out)
}
