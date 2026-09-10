package userop

import (
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"testing"
)

// vectorPath is the fixture the Solidity side generates. Read directly rather
// than copied: a copy is a second thing that can drift.
const vectorPath = "../../../contracts/test/fixtures/userop_vector.json"

// vector mirrors contracts/test/fixtures/userop_vector.json.
//
// Every numeric field is json.Number, never a float64. maxCost in the fixture is
// 5e17, which is past 2^53 — decoding it through a float would silently round
// it, and the resulting hash would be wrong in a way no assertion here would
// explain. Same rule as money.Amount, for the same reason.
type vector struct {
	ChainID    json.Number `json:"chainId"`
	EntryPoint string      `json:"entryPoint"`
	Paymaster  string      `json:"paymaster"`

	Sender               string      `json:"sender"`
	Nonce                json.Number `json:"nonce"`
	InitCode             string      `json:"initCode"`
	CallData             string      `json:"callData"`
	VerificationGasLimit json.Number `json:"verificationGasLimit"`
	CallGasLimit         json.Number `json:"callGasLimit"`
	PreVerificationGas   json.Number `json:"preVerificationGas"`
	MaxPriorityFeePerGas json.Number `json:"maxPriorityFeePerGas"`
	MaxFeePerGas         json.Number `json:"maxFeePerGas"`

	PaymasterVerificationGasLimit json.Number `json:"paymasterVerificationGasLimit"`
	PaymasterPostOpGasLimit       json.Number `json:"paymasterPostOpGasLimit"`
	ValidUntil                    json.Number `json:"validUntil"`
	ValidAfter                    json.Number `json:"validAfter"`
	MaxCost                       json.Number `json:"maxCost"`

	PaymasterAndData string `json:"paymasterAndData"`
	UserOpHash       string `json:"userOpHash"`
	ApprovalHash     string `json:"approvalHash"`
}

func loadVector(t *testing.T) vector {
	t.Helper()
	raw, err := os.ReadFile(filepath.Clean(vectorPath))
	if err != nil {
		t.Fatalf("read fixture: %v (run `make userop-vector`)", err)
	}
	var v vector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return v
}

func mustBig(t *testing.T, n json.Number) *big.Int {
	t.Helper()
	v, ok := new(big.Int).SetString(n.String(), 10)
	if !ok {
		t.Fatalf("not an integer: %q", n.String())
	}
	return v
}

func mustUint64(t *testing.T, n json.Number) uint64 {
	t.Helper()
	return mustBig(t, n).Uint64()
}
