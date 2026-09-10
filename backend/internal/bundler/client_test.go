package bundler

import (
	"context"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ethereum/go-ethereum/common"

	"github.com/kenkomu/sokoni/backend/internal/chain"
	"github.com/kenkomu/sokoni/backend/internal/userop"
)

var entryPointV07 = common.HexToAddress(chain.EntryPointV07)

// stub records what the client sent and replies with whatever the test wants.
type stub struct {
	*httptest.Server
	lastMethod string
	lastParams []json.RawMessage
	calls      int
}

func newStub(t *testing.T, reply func(method string) (any, *chain.RPCError)) *stub {
	t.Helper()
	s := &stub{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID     uint64            `json:"id"`
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode request: %v", err)
		}
		s.lastMethod, s.lastParams = req.Method, req.Params
		s.calls++

		result, rpcErr := reply(req.Method)
		out := map[string]any{"jsonrpc": "2.0", "id": req.ID}
		if rpcErr != nil {
			out["error"] = rpcErr
		} else {
			out["result"] = result
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(out); err != nil {
			t.Errorf("encode reply: %v", err)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func testOp() *userop.UserOperation {
	return &userop.UserOperation{
		Sender:               common.HexToAddress("0xA1"),
		Nonce:                big.NewInt(3),
		CallData:             []byte{0xC0, 0xDE},
		VerificationGasLimit: big.NewInt(600_000),
		CallGasLimit:         big.NewInt(400_000),
		PreVerificationGas:   big.NewInt(100_000),
		MaxPriorityFeePerGas: big.NewInt(1e9),
		MaxFeePerGas:         big.NewInt(1e11),
		Signature:            []byte{0xAB},
	}
}

func TestSendUserOperationPostsUnpackedFormAndEntryPoint(t *testing.T) {
	s := newStub(t, func(string) (any, *chain.RPCError) {
		return "0x" + common.Hash{31: 9}.Hex()[2:], nil
	})
	c := New(s.URL, entryPointV07, 50)

	hash, err := c.SendUserOperation(context.Background(), testOp())
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	if hash == (common.Hash{}) {
		t.Fatal("expected a userOpHash back")
	}
	if s.lastMethod != "eth_sendUserOperation" {
		t.Errorf("method = %q", s.lastMethod)
	}
	if len(s.lastParams) != 2 {
		t.Fatalf("expected [op, entryPoint], got %d params", len(s.lastParams))
	}

	// Second param must be the EntryPoint address.
	var ep string
	if err := json.Unmarshal(s.lastParams[1], &ep); err != nil {
		t.Fatal(err)
	}
	if common.HexToAddress(ep) != entryPointV07 {
		t.Errorf("entryPoint = %s, want %s", ep, entryPointV07)
	}

	// First param must be the unpacked form, not the packed one.
	var op map[string]any
	if err := json.Unmarshal(s.lastParams[0], &op); err != nil {
		t.Fatal(err)
	}
	for _, packed := range []string{"accountGasLimits", "gasFees", "paymasterAndData", "initCode"} {
		if _, ok := op[packed]; ok {
			t.Errorf("sent packed field %q; bundlers expect the unpacked form", packed)
		}
	}
	for _, want := range []string{"sender", "nonce", "callGasLimit", "verificationGasLimit", "signature"} {
		if _, ok := op[want]; !ok {
			t.Errorf("missing required field %q", want)
		}
	}
}

// The numeric codes are the real debugging surface of ERC-4337; a bare
// "AA33 reverted" names the stage and nothing else.
func TestRejectionCodesAreAnnotated(t *testing.T) {
	tests := []struct {
		code int
		want string
	}{
		{-32501, "paymaster rejected"},
		{-32503, "validity window"},
		{-32505, "stake"},
		{-32507, "signature"},
	}
	for _, tc := range tests {
		s := newStub(t, func(string) (any, *chain.RPCError) {
			return nil, &chain.RPCError{Code: tc.code, Message: "AA33 reverted"}
		})
		c := New(s.URL, entryPointV07, 50)

		_, err := c.SendUserOperation(context.Background(), testOp())
		if err == nil {
			t.Fatalf("code %d: expected an error", tc.code)
		}
		if !contains(err.Error(), tc.want) {
			t.Errorf("code %d: %q should mention %q", tc.code, err.Error(), tc.want)
		}
		// The original RPC error must stay unwrappable underneath the hint.
		var rpcErr *chain.RPCError
		if !errors.As(err, &rpcErr) || rpcErr.Code != tc.code {
			t.Errorf("code %d: original RPCError must remain wrapped", tc.code)
		}
	}
}

func TestUnknownRejectionCodePassesThrough(t *testing.T) {
	s := newStub(t, func(string) (any, *chain.RPCError) {
		return nil, &chain.RPCError{Code: -32000, Message: "something else"}
	})
	c := New(s.URL, entryPointV07, 50)

	_, err := c.SendUserOperation(context.Background(), testOp())
	var rpcErr *chain.RPCError
	if !errors.As(err, &rpcErr) || rpcErr.Code != -32000 {
		t.Fatalf("expected the raw RPCError, got %v", err)
	}
}

func TestGetUserOperationReceiptReturnsNilWhenPending(t *testing.T) {
	s := newStub(t, func(string) (any, *chain.RPCError) { return nil, nil })
	c := New(s.URL, entryPointV07, 50)

	got, err := c.GetUserOperationReceipt(context.Background(), common.Hash{1})
	if err != nil {
		t.Fatalf("receipt: %v", err)
	}
	if got != nil {
		t.Fatalf("a pending operation must return nil, got %+v", got)
	}
}

func TestGetUserOperationReceiptParsesNestedTxReceipt(t *testing.T) {
	s := newStub(t, func(string) (any, *chain.RPCError) {
		return map[string]any{
			"userOpHash":    "0x" + common.Hash{31: 7}.Hex()[2:],
			"sender":        "0x00000000000000000000000000000000000000a1",
			"paymaster":     "0x00000000000000000000000000000000000000b2",
			"nonce":         "0x3",
			"actualGasCost": "0x2386f26fc10000",
			"actualGasUsed": "0x1e8480",
			"success":       true,
			"receipt": map[string]any{
				"transactionHash": "0x" + common.Hash{31: 8}.Hex()[2:],
				"blockNumber":     "0x62870d2",
			},
		}, nil
	})
	c := New(s.URL, entryPointV07, 50)

	got, err := c.GetUserOperationReceipt(context.Background(), common.Hash{1})
	if err != nil {
		t.Fatalf("receipt: %v", err)
	}
	if !got.Success {
		t.Error("success should be true")
	}
	if got.BlockNumber != 0x62870d2 {
		t.Errorf("blockNumber = %d", got.BlockNumber)
	}
	if got.ActualGasCost.Cmp(big.NewInt(0x2386f26fc10000)) != 0 {
		t.Errorf("actualGasCost = %s", got.ActualGasCost)
	}
	if got.Paymaster != common.HexToAddress("0xb2") {
		t.Errorf("paymaster = %s", got.Paymaster)
	}
}

// A bundler pointed at the wrong EntryPoint version fails every operation with
// an error that never says so. Check it at boot instead.
func TestSupportsConfiguredEntryPoint(t *testing.T) {
	s := newStub(t, func(string) (any, *chain.RPCError) {
		return []string{chain.EntryPointV06}, nil
	})
	c := New(s.URL, entryPointV07, 50)

	ok, err := c.SupportsConfiguredEntryPoint(context.Background())
	if err != nil {
		t.Fatalf("supported: %v", err)
	}
	if ok {
		t.Fatal("a v0.6-only bundler must not report support for our v0.7 EntryPoint")
	}

	s2 := newStub(t, func(string) (any, *chain.RPCError) {
		return []string{chain.EntryPointV06, chain.EntryPointV07}, nil
	})
	c2 := New(s2.URL, entryPointV07, 50)
	ok, err = c2.SupportsConfiguredEntryPoint(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("expected support to be reported")
	}
}

func TestEstimateParsesPartialResponses(t *testing.T) {
	// Not every bundler returns the paymaster fields.
	s := newStub(t, func(string) (any, *chain.RPCError) {
		return map[string]any{
			"preVerificationGas":   "0x186a0",
			"verificationGasLimit": "0x927c0",
			"callGasLimit":         "0x61a80",
		}, nil
	})
	c := New(s.URL, entryPointV07, 50)

	est, err := c.EstimateUserOperationGas(context.Background(), testOp())
	if err != nil {
		t.Fatalf("estimate: %v", err)
	}
	if est.CallGasLimit.Cmp(big.NewInt(400_000)) != 0 {
		t.Errorf("callGasLimit = %s", est.CallGasLimit)
	}
	if est.PaymasterPostOpGasLimit != nil {
		t.Errorf("absent field should stay nil, got %s", est.PaymasterPostOpGasLimit)
	}
}

// A cancelled context must stop the client rather than burn retries.
func TestContextCancellationStops(t *testing.T) {
	s := newStub(t, func(string) (any, *chain.RPCError) {
		return nil, &chain.RPCError{Code: -32007, Message: "50/second request limit reached"}
	})
	c := New(s.URL, entryPointV07, 50)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, err := c.SendUserOperation(ctx, testOp()); err == nil {
		t.Fatal("expected an error from a cancelled context")
	}
}

func contains(haystack, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}
