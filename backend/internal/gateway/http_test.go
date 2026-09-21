package gateway

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/kenkomu/sokoni/backend/internal/store"
)

func newServer(t *testing.T) (*rig, *httptest.Server) {
	t.Helper()
	r := newRig(t)
	srv := httptest.NewServer(NewHandler(r.svc, r.hub, quietLog()))
	t.Cleanup(srv.Close)
	return r, srv
}

func do(t *testing.T, method, url string, body any) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if s, ok := body.(string); ok {
			buf.WriteString(s)
		} else if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatal(err)
		}
	}
	req, err := http.NewRequest(method, url, &buf)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// hex32 renders an integer the way the phone does: 0x plus exactly 64 hex
// digits, zero-padded. See PublicKeyCoords.xHex and Signature.rHex.
func hex32(t *testing.T, v fmt.Stringer) string {
	t.Helper()
	n, ok := v.(interface{ Text(int) string })
	if !ok {
		t.Fatalf("not an integer: %v", v)
	}
	return "0x" + fmt.Sprintf("%064s", n.Text(16))
}

// The phone ↔ gateway contract, pinned from the Go side. The request bodies
// here are exactly what the Flutter client puts on the wire: coordinates and
// scalars zero-padded to 32 bytes, and the assertion in the shape
// PasskeyAssertion.toJson() emits. mobile/test/api_test.dart pins the same
// shapes from the other side.
func TestHTTPFullFlowWithThePhonesWireFormat(t *testing.T) {
	requirePython(t)
	r, srv := newServer(t)
	owner := testPasskey(t)

	status, acct := do(t, "POST", srv.URL+"/v1/accounts", map[string]any{
		"credentialId": cred,
		"x":            hex32(t, owner.X),
		"y":            hex32(t, owner.Y),
	})
	if status != http.StatusCreated {
		t.Fatalf("register: %d %v", status, acct)
	}
	if acct["address"] != testAccount.Hex() {
		t.Fatalf("address = %v, want %s", acct["address"], testAccount.Hex())
	}

	status, prep := do(t, "POST", srv.URL+"/v1/ops", map[string]any{
		"credentialId": cred,
		"intent":       map[string]any{"kind": "transfer", "token": testToken.Hex(), "to": testRecipient.Hex(), "amount": "250000"},
	})
	if status != http.StatusCreated {
		t.Fatalf("prepare: %d %v", status, prep)
	}
	opID, _ := prep["opId"].(string)
	challenge, _ := prep["challenge"].(string)

	a := signWithTestPasskey(t, common.HexToHash(challenge))
	status, sub := do(t, "POST", srv.URL+"/v1/ops/"+opID+"/submit", map[string]any{
		"credentialId":      cred,
		"authenticatorData": "0x" + common.Bytes2Hex(a.AuthenticatorData),
		"clientDataJSON":    a.ClientDataJSON,
		"challengeIndex":    a.ChallengeIndex,
		"typeIndex":         a.TypeIndex,
		"r":                 hex32(t, a.R),
		"s":                 hex32(t, a.S),
	})
	if status != http.StatusAccepted {
		t.Fatalf("submit: %d %v", status, sub)
	}
	if sub["userOpHash"] != challenge {
		t.Errorf("userOpHash = %v, want %s", sub["userOpHash"], challenge)
	}
	if n := r.bundler.count(); n != 1 {
		t.Fatalf("bundler received %d operations, want 1", n)
	}

	status, st := do(t, "GET", srv.URL+"/v1/ops/"+opID, nil)
	if status != http.StatusOK || st["status"] != StatusSubmitted {
		t.Fatalf("status: %d %v", status, st)
	}
}

// The trap parseWord exists to avoid: hexutil.DecodeBig rejects leading zeros,
// and the phone zero-pads every value, so a strict decoder would refuse
// roughly one key in 256.
func TestParseWord(t *testing.T) {
	ok := map[string]int64{"0x00ab": 0xab, "0x01": 1, "0xFF": 255, "0x" + strings.Repeat("0", 62) + "2a": 42}
	for in, want := range ok {
		got, valid := parseWord(in)
		if !valid || got.Int64() != want {
			t.Errorf("parseWord(%q) = %v, %v; want %d", in, got, valid, want)
		}
	}
	for _, bad := range []string{"", "0x", "ab", "0xzz", "0xabc", "0x" + strings.Repeat("11", 33)} {
		if _, valid := parseWord(bad); valid {
			t.Errorf("parseWord(%q) must be refused", bad)
		}
	}
}

func TestErrorsHaveAStableShape(t *testing.T) {
	_, srv := newServer(t)
	status, body := do(t, "GET", srv.URL+"/v1/ops/op_nope", nil)
	if status != http.StatusNotFound {
		t.Fatalf("status %d, want 404", status)
	}
	if body["error"] != "unknown_op" {
		t.Errorf("error = %v, want unknown_op", body["error"])
	}
	if msg, _ := body["message"].(string); msg == "" {
		t.Error("every error carries a message for a person")
	}
}

func TestMalformedJSONIs400(t *testing.T) {
	_, srv := newServer(t)
	status, body := do(t, "POST", srv.URL+"/v1/accounts", "{not json")
	if status != http.StatusBadRequest || body["error"] != "bad_json" {
		t.Fatalf("got %d %v, want 400 bad_json", status, body)
	}
}

func TestRequestBodiesAreBounded(t *testing.T) {
	_, srv := newServer(t)
	huge := `{"credentialId":"` + strings.Repeat("a", maxBody+1) + `"}`
	if status, _ := do(t, "POST", srv.URL+"/v1/accounts", huge); status != http.StatusBadRequest {
		t.Fatalf("an oversized body must be refused, got %d", status)
	}
}

// assetLinksStatement's top level is a JSON array, not an object, so it can't
// go through do()'s map[string]any decode -- Decode into a map on an array
// body fails silently (the error is swallowed there on purpose, since most
// endpoints do return an object), which would make this test pass for the
// wrong reason.
func TestAssetLinksNamesThePackageAndFingerprint(t *testing.T) {
	r, srv := newServer(t)
	r.svc.cfg.AndroidPackageName = "app.sokoni"
	r.svc.cfg.AndroidCertFingerprints = []string{"AA:BB:CC"}

	resp, err := http.Get(srv.URL + "/.well-known/assetlinks.json")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("content-type = %q, want application/json — Android's own check requires it", ct)
	}
	var statements []assetLinksStatement
	if err := json.NewDecoder(resp.Body).Decode(&statements); err != nil {
		t.Fatal(err)
	}
	if len(statements) != 1 {
		t.Fatalf("statements = %v, want exactly one", statements)
	}
	s := statements[0]
	if s.Relation[0] != "delegate_permission/common.get_login_creds" {
		t.Errorf("relation = %v", s.Relation)
	}
	if s.Target.PackageName != "app.sokoni" {
		t.Errorf("package_name = %q", s.Target.PackageName)
	}
	if len(s.Target.SHA256CertFingerprints) != 1 || s.Target.SHA256CertFingerprints[0] != "AA:BB:CC" {
		t.Errorf("sha256_cert_fingerprints = %v", s.Target.SHA256CertFingerprints)
	}
}

func TestAssetLinksIsEmptyWithoutConfiguration(t *testing.T) {
	r, srv := newServer(t)
	r.svc.cfg.AndroidPackageName = ""
	r.svc.cfg.AndroidCertFingerprints = nil

	resp, err := http.Get(srv.URL + "/.well-known/assetlinks.json")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var statements []assetLinksStatement
	if err := json.NewDecoder(resp.Body).Decode(&statements); err != nil {
		t.Fatal(err)
	}
	if len(statements) != 0 {
		t.Fatalf("statements = %v, want none when unconfigured", statements)
	}
}

func TestConfigListsSponsoredTokens(t *testing.T) {
	_, srv := newServer(t)
	status, body := do(t, "GET", srv.URL+"/v1/config", nil)
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	if body["chainId"] != float64(10143) {
		t.Errorf("chainId = %v", body["chainId"])
	}
	tokens, _ := body["sponsoredTokens"].([]any)
	if len(tokens) != 1 || tokens[0].(map[string]any)["symbol"] != "TST" {
		t.Errorf("sponsoredTokens = %v", tokens)
	}
}

func TestMarketsListsEnabledMarkets(t *testing.T) {
	r, srv := newServer(t)
	r.markets.markets = []store.Market{
		{Symbol: "MON-USDC", BaseToken: make([]byte, 20), QuoteToken: testToken.Bytes(),
			BaseDec: 18, QuoteDec: 6, Venue: "kuru", TickSize: "0.000001000000000000", MinQty: "0.000002000000000000"},
	}

	status, body := do(t, "GET", srv.URL+"/v1/markets", nil)
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	markets, _ := body["markets"].([]any)
	if len(markets) != 1 {
		t.Fatalf("markets = %v, want 1", markets)
	}
	m := markets[0].(map[string]any)
	if m["symbol"] != "MON-USDC" || m["tickSize"] != "0.000001000000000000" {
		t.Errorf("market = %v", m)
	}
}

func TestCandlesUnknownMarket404s(t *testing.T) {
	_, srv := newServer(t)
	status, body := do(t, "GET", srv.URL+"/v1/markets/NOPE/candles", nil)
	if status != http.StatusNotFound {
		t.Fatalf("status %d, want 404: %v", status, body)
	}
}

func TestCandlesRejectsUnsupportedInterval(t *testing.T) {
	r, srv := newServer(t)
	r.markets.markets = []store.Market{{Symbol: "MON-USDC"}}

	// 900 (15m) is one of Kuru's own documented granularities but not one
	// store.ApplyBlocks populates (candleIntervalsS: 60/300/3600/86400) --
	// still a genuinely unsupported value, unlike 300 which this test used
	// before multi-interval candles existed.
	status, body := do(t, "GET", srv.URL+"/v1/markets/MON-USDC/candles?interval=900", nil)
	if status != http.StatusBadRequest {
		t.Fatalf("status %d, want 400: %v", status, body)
	}
}

func TestCandlesReturnsSeededRows(t *testing.T) {
	r, srv := newServer(t)
	r.markets.markets = []store.Market{{Symbol: "MON-USDC"}}
	r.markets.candles["MON-USDC"] = []store.Candle{
		{BucketTS: time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC), Open: "1", High: "1", Low: "1", Close: "1", Volume: "1", TradeCount: 1},
	}

	status, body := do(t, "GET", srv.URL+"/v1/markets/MON-USDC/candles", nil)
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	candles, _ := body["candles"].([]any)
	if len(candles) != 1 {
		t.Fatalf("candles = %v, want 1", candles)
	}
}

func TestTradesReturnsMostRecentFirst(t *testing.T) {
	r, srv := newServer(t)
	r.markets.markets = []store.Market{{Symbol: "MON-USDC"}}
	r.markets.trades["MON-USDC"] = []store.Trade{
		{FillID: 2, Side: "buy", Px: "1", Qty: "1", BlockNumber: 200, TxHash: make([]byte, 32)},
		{FillID: 1, Side: "sell", Px: "1", Qty: "1", BlockNumber: 100, TxHash: make([]byte, 32)},
	}

	status, body := do(t, "GET", srv.URL+"/v1/markets/MON-USDC/trades?limit=1", nil)
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	trades, _ := body["trades"].([]any)
	if len(trades) != 1 {
		t.Fatalf("trades = %v, want 1", trades)
	}
	if trades[0].(map[string]any)["fillId"] != float64(2) {
		t.Errorf("trades[0] = %v, want fillId 2 (most recent)", trades[0])
	}
}

// Upstream failures carry the bundler's own reason, so a rejection seen on a
// device can be diagnosed without reading server logs.
func TestUpstreamFailuresCarryTheirDetail(t *testing.T) {
	requirePython(t)
	r, srv := newServer(t)
	owner := testPasskey(t)
	do(t, "POST", srv.URL+"/v1/accounts", map[string]any{"credentialId": cred, "x": hex32(t, owner.X), "y": hex32(t, owner.Y)})
	_, prep := do(t, "POST", srv.URL+"/v1/ops", map[string]any{
		"credentialId": cred,
		"intent":       map[string]any{"kind": "transfer", "token": testToken.Hex(), "to": testRecipient.Hex(), "amount": "1"},
	})
	opID, _ := prep["opId"].(string)
	a := signWithTestPasskey(t, common.HexToHash(prep["challenge"].(string)))

	r.bundler.setErr(errors.New("rpc error -32505: paymaster stake too low"))
	status, body := do(t, "POST", srv.URL+"/v1/ops/"+opID+"/submit", map[string]any{
		"authenticatorData": "0x" + common.Bytes2Hex(a.AuthenticatorData),
		"clientDataJSON":    a.ClientDataJSON,
		"challengeIndex":    a.ChallengeIndex,
		"typeIndex":         a.TypeIndex,
		"r":                 hex32(t, a.R),
		"s":                 hex32(t, a.S),
	})
	if status != http.StatusBadGateway {
		t.Fatalf("status %d, want 502", status)
	}
	if d, _ := body["detail"].(string); !strings.Contains(d, "-32505") {
		t.Errorf("detail should carry the bundler's reason, got %q", d)
	}
}
