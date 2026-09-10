package userop

import (
	"encoding/json"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

// fromVector rebuilds the fixture's operation, paymasterAndData included, so the
// hash covers exactly the bytes the EntryPoint hashed.
func fromVector(t *testing.T, v vector) *UserOperation {
	t.Helper()
	initCode, err := hexutil.Decode(v.InitCode)
	if err != nil {
		t.Fatalf("initCode: %v", err)
	}
	callData, err := hexutil.Decode(v.CallData)
	if err != nil {
		t.Fatalf("callData: %v", err)
	}
	pmd, err := hexutil.Decode(v.PaymasterAndData)
	if err != nil {
		t.Fatalf("paymasterAndData: %v", err)
	}
	return &UserOperation{
		Sender:               common.HexToAddress(v.Sender),
		Nonce:                mustBig(t, v.Nonce),
		InitCode:             initCode,
		CallData:             callData,
		VerificationGasLimit: mustBig(t, v.VerificationGasLimit),
		CallGasLimit:         mustBig(t, v.CallGasLimit),
		PreVerificationGas:   mustBig(t, v.PreVerificationGas),
		MaxPriorityFeePerGas: mustBig(t, v.MaxPriorityFeePerGas),
		MaxFeePerGas:         mustBig(t, v.MaxFeePerGas),
		PaymasterAndData:     pmd,
	}
}

// The one that matters. If this fails, the backend is handing the phone a hash
// the account will never accept, and the only symptom downstream is an opaque
// signature error from a bundler.
func TestHashMatchesTheEntryPoint(t *testing.T) {
	v := loadVector(t)
	op := fromVector(t, v)

	got, err := op.Hash(common.HexToAddress(v.EntryPoint), mustBig(t, v.ChainID))
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if want := common.HexToHash(v.UserOpHash); got != want {
		t.Fatalf("userOpHash mismatch\n got %s\nwant %s", got, want)
	}
}

// The hash binds to the EntryPoint and the chain, so an operation signed for one
// cannot be replayed on the other.
func TestHashIsBoundToEntryPointAndChain(t *testing.T) {
	v := loadVector(t)
	op := fromVector(t, v)
	base, _ := op.Hash(common.HexToAddress(v.EntryPoint), mustBig(t, v.ChainID))

	// Derived from the fixture so it cannot collide with the pinned chain.
	otherChain, err := op.Hash(common.HexToAddress(v.EntryPoint),
		new(big.Int).Add(mustBig(t, v.ChainID), big.NewInt(1)))
	if err != nil {
		t.Fatal(err)
	}
	if otherChain == base {
		t.Fatal("hash must change with the chain id")
	}

	otherEP, err := op.Hash(common.HexToAddress("0x00000000000000000000000000000000000000ff"), mustBig(t, v.ChainID))
	if err != nil {
		t.Fatal(err)
	}
	if otherEP == base {
		t.Fatal("hash must change with the entry point")
	}
}

func TestPackedGasFieldOrdering(t *testing.T) {
	op := &UserOperation{
		VerificationGasLimit: big.NewInt(0x1111),
		CallGasLimit:         big.NewInt(0x2222),
		MaxPriorityFeePerGas: big.NewInt(0x3333),
		MaxFeePerGas:         big.NewInt(0x4444),
	}

	// verificationGasLimit occupies the high half, callGasLimit the low —
	// the reverse of the order the JSON-RPC form lists them in.
	gl, err := op.AccountGasLimits()
	if err != nil {
		t.Fatal(err)
	}
	if got := new(big.Int).SetBytes(gl[:16]); got.Cmp(big.NewInt(0x1111)) != 0 {
		t.Fatalf("high half should be verificationGasLimit, got %x", got)
	}
	if got := new(big.Int).SetBytes(gl[16:]); got.Cmp(big.NewInt(0x2222)) != 0 {
		t.Fatalf("low half should be callGasLimit, got %x", got)
	}

	gf, err := op.GasFees()
	if err != nil {
		t.Fatal(err)
	}
	if got := new(big.Int).SetBytes(gf[:16]); got.Cmp(big.NewInt(0x3333)) != 0 {
		t.Fatalf("high half should be maxPriorityFeePerGas, got %x", got)
	}
	if got := new(big.Int).SetBytes(gf[16:]); got.Cmp(big.NewInt(0x4444)) != 0 {
		t.Fatalf("low half should be maxFeePerGas, got %x", got)
	}
}

// A gas field that does not fit its half of the word would silently corrupt the
// other half. Refuse instead.
func TestOversizedGasFieldIsRejected(t *testing.T) {
	tooBig := new(big.Int).Lsh(big.NewInt(1), 128)
	op := &UserOperation{
		VerificationGasLimit: tooBig,
		CallGasLimit:         big.NewInt(1),
	}
	if _, err := op.AccountGasLimits(); err == nil {
		t.Fatal("expected a uint128 overflow error")
	}
}

func TestNilGasFieldIsRejected(t *testing.T) {
	op := &UserOperation{CallGasLimit: big.NewInt(1)}
	if _, err := op.AccountGasLimits(); err == nil {
		t.Fatal("expected an error for a nil gas field")
	}
}

// Bundlers speak the unpacked form: initCode splits into factory/factoryData,
// and paymasterAndData into four fields.
func TestMarshalJSONEmitsTheUnpackedForm(t *testing.T) {
	v := loadVector(t)
	op := fromVector(t, v)
	op.Signature = []byte{0xAB, 0xCD}

	raw, err := json.Marshal(op)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got map[string]string
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	// The packed field names must not appear on the wire at all.
	for _, banned := range []string{"accountGasLimits", "gasFees", "paymasterAndData", "initCode"} {
		if _, ok := got[banned]; ok {
			t.Errorf("%q is the packed form and must not be sent to a bundler", banned)
		}
	}

	want := map[string]string{
		"factory":                       "0x00000000000000000000000000000000000000F2",
		"factoryData":                   "0xdeadbeef",
		"paymaster":                     common.HexToAddress(v.Paymaster).Hex(),
		"paymasterVerificationGasLimit": "0x1d4c0",
		"paymasterPostOpGasLimit":       "0x0",
		"callGasLimit":                  "0x61a80",
		"verificationGasLimit":          "0x927c0",
		"signature":                     "0xabcd",
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s = %q, want %q", k, got[k], w)
		}
	}
}

// An account that is already deployed and an operation with no sponsor must omit
// those groups entirely. A bundler reading `"paymaster":"0x0..0"` will try to
// call it.
func TestMarshalJSONOmitsAbsentGroups(t *testing.T) {
	op := &UserOperation{
		Sender:               common.HexToAddress("0xA1"),
		Nonce:                big.NewInt(1),
		CallData:             []byte{},
		VerificationGasLimit: big.NewInt(1),
		CallGasLimit:         big.NewInt(1),
		PreVerificationGas:   big.NewInt(1),
		MaxPriorityFeePerGas: big.NewInt(1),
		MaxFeePerGas:         big.NewInt(1),
		Signature:            []byte{},
	}
	raw, err := json.Marshal(op)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got map[string]string
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	for _, absent := range []string{"factory", "factoryData", "paymaster", "paymasterData"} {
		if _, ok := got[absent]; ok {
			t.Errorf("%q must be omitted when unused, got %q", absent, got[absent])
		}
	}
}

func TestMarshalJSONRejectsTruncatedPaymasterData(t *testing.T) {
	op := &UserOperation{
		Sender:               common.HexToAddress("0xA1"),
		Nonce:                big.NewInt(1),
		VerificationGasLimit: big.NewInt(1),
		CallGasLimit:         big.NewInt(1),
		PreVerificationGas:   big.NewInt(1),
		MaxPriorityFeePerGas: big.NewInt(1),
		MaxFeePerGas:         big.NewInt(1),
		// 20 bytes: an address, but no room for the two gas limits.
		PaymasterAndData: make([]byte, 20),
	}
	if _, err := json.Marshal(op); err == nil {
		t.Fatal("expected an error for paymasterAndData shorter than 52 bytes")
	}
}
