package paymaster

import (
	"bytes"
	"crypto/ecdsa"
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/kenkomu/sokoni/backend/internal/userop"
)

const vectorPath = "../../../contracts/test/fixtures/userop_vector.json"

// Numbers stay json.Number: maxCost is 5e17, past the range float64 represents
// exactly, and a rounded maxCost hashes to something the contract will reject.
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

func mustBytes(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hexutil.Decode(s)
	if err != nil {
		t.Fatalf("decode %q: %v", s, err)
	}
	return b
}

func fixtureOp(t *testing.T, v vector) *userop.UserOperation {
	t.Helper()
	return &userop.UserOperation{
		Sender:               common.HexToAddress(v.Sender),
		Nonce:                mustBig(t, v.Nonce),
		InitCode:             mustBytes(t, v.InitCode),
		CallData:             mustBytes(t, v.CallData),
		VerificationGasLimit: mustBig(t, v.VerificationGasLimit),
		CallGasLimit:         mustBig(t, v.CallGasLimit),
		PreVerificationGas:   mustBig(t, v.PreVerificationGas),
		MaxPriorityFeePerGas: mustBig(t, v.MaxPriorityFeePerGas),
		MaxFeePerGas:         mustBig(t, v.MaxFeePerGas),
		PaymasterAndData:     mustBytes(t, v.PaymasterAndData),
	}
}

// Generated per run rather than hardcoded. The approval digest commits to the
// paymaster address, not the signer's, so any key proves the same things — and
// a 64-hex-character constant in the tree is exactly the shape the secret
// scanners exist to catch.
func testKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return key
}

func fixtureSponsor(t *testing.T, v vector) *Sponsor {
	t.Helper()
	s, err := NewSponsorWithKey(common.HexToAddress(v.Paymaster), mustBig(t, v.ChainID), testKey(t))
	if err != nil {
		t.Fatalf("new sponsor: %v", err)
	}
	s.VerificationGasLimit = mustBig(t, v.PaymasterVerificationGasLimit)
	s.PostOpGasLimit = mustBig(t, v.PaymasterPostOpGasLimit)
	return s
}

// The cross-stack check. A mismatch here means every sponsorship is rejected
// on-chain with nothing but "AA34 signature error" to go on.
func TestApprovalHashMatchesTheContract(t *testing.T) {
	v := loadVector(t)
	s := fixtureSponsor(t, v)
	op := fixtureOp(t, v)

	got, err := s.ApprovalHash(op,
		mustBig(t, v.ValidUntil).Uint64(),
		mustBig(t, v.ValidAfter).Uint64(),
		mustBig(t, v.MaxCost))
	if err != nil {
		t.Fatalf("approval hash: %v", err)
	}
	if want := common.HexToHash(v.ApprovalHash); got != want {
		t.Fatalf("approvalHash mismatch\n got %s\nwant %s", got, want)
	}
}

// The byte layout must match what SokoniPaymaster parses, field for field.
func TestEncodeMatchesTheContractLayout(t *testing.T) {
	v := loadVector(t)
	s := fixtureSponsor(t, v)

	dummy := bytes.Repeat([]byte{0x01}, 65)
	got, err := s.encode(
		mustBig(t, v.ValidUntil).Uint64(),
		mustBig(t, v.ValidAfter).Uint64(),
		mustBig(t, v.MaxCost),
		dummy)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if len(got) != DataLength {
		t.Fatalf("length %d, want %d", len(got), DataLength)
	}
	if want := mustBytes(t, v.PaymasterAndData); !bytes.Equal(got, want) {
		t.Fatalf("paymasterAndData mismatch\n got %x\nwant %x", got, want)
	}
}

// What the contract does: prefix the digest, then ecrecover, then compare
// against the registered signer.
func TestApprovalRecoversToTheSigner(t *testing.T) {
	v := loadVector(t)
	s := fixtureSponsor(t, v)
	op := fixtureOp(t, v)

	validUntil := mustBig(t, v.ValidUntil).Uint64()
	validAfter := mustBig(t, v.ValidAfter).Uint64()
	maxCost := mustBig(t, v.MaxCost)

	pmd, err := s.Approve(op, validUntil, validAfter, maxCost)
	if err != nil {
		t.Fatalf("approve: %v", err)
	}
	if len(pmd) != DataLength {
		t.Fatalf("length %d, want %d", len(pmd), DataLength)
	}

	digest, err := s.ApprovalHash(op, validUntil, validAfter, maxCost)
	if err != nil {
		t.Fatal(err)
	}

	sig := bytes.Clone(pmd[signatureOffset:])
	if sig[64] != 27 && sig[64] != 28 {
		t.Fatalf("v must be 27 or 28 for Solidity ecrecover, got %d", sig[64])
	}
	sig[64] -= 27 // go-ethereum recovery wants 0/1

	pub, err := crypto.SigToPub(ethSignedMessageHash(digest), sig)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if got := crypto.PubkeyToAddress(*pub); got != s.SignerAddress() {
		t.Fatalf("recovered %s, want %s", got, s.SignerAddress())
	}
}

// OpenZeppelin v5 rejects high-s signatures. go-ethereum signs canonically, but
// this is the same malleability rule the P-256 side enforces by hand, so assert
// it rather than assume it.
func TestApprovalSignatureIsLowS(t *testing.T) {
	v := loadVector(t)
	s := fixtureSponsor(t, v)
	op := fixtureOp(t, v)

	halfN := new(big.Int).Rsh(crypto.S256().Params().N, 1)
	for i := range 16 {
		op.Nonce = big.NewInt(int64(i))
		pmd, err := s.Approve(op, 0, 0, big.NewInt(1))
		if err != nil {
			t.Fatalf("approve: %v", err)
		}
		got := new(big.Int).SetBytes(pmd[signatureOffset+32 : signatureOffset+64])
		if got.Cmp(halfN) > 0 {
			t.Fatalf("nonce %d produced a high-s signature", i)
		}
	}
}

// Approve must leave the operation as it found it: the caller assigns the
// result, and a stub left behind would be hashed into the userOpHash.
func TestApproveDoesNotMutateTheOperation(t *testing.T) {
	v := loadVector(t)
	s := fixtureSponsor(t, v)
	op := fixtureOp(t, v)

	before := bytes.Clone(op.PaymasterAndData)
	if _, err := s.Approve(op, 0, 0, big.NewInt(1)); err != nil {
		t.Fatalf("approve: %v", err)
	}
	if !bytes.Equal(op.PaymasterAndData, before) {
		t.Fatal("Approve must not leave its stub on the operation")
	}
}

func TestApproveRejectsBadInputs(t *testing.T) {
	v := loadVector(t)
	s := fixtureSponsor(t, v)
	op := fixtureOp(t, v)

	tests := []struct {
		name                   string
		validUntil, validAfter uint64
		maxCost                *big.Int
	}{
		{"validUntil past uint48", 1 << 48, 0, big.NewInt(1)},
		{"validAfter past uint48", 0, 1 << 48, big.NewInt(1)},
		{"window closes before it opens", 100, 200, big.NewInt(1)},
		{"maxCost past uint128", 0, 0, new(big.Int).Lsh(big.NewInt(1), 128)},
		{"negative maxCost", 0, 0, big.NewInt(-1)},
		{"nil maxCost", 0, 0, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := s.Approve(op, tc.validUntil, tc.validAfter, tc.maxCost); err == nil {
				t.Fatal("expected an error")
			}
		})
	}
}

func TestNewSponsorRejectsBadKeyOrChain(t *testing.T) {
	addr := common.HexToAddress("0xA1")
	key := testKey(t)

	if _, err := NewSponsor(addr, big.NewInt(143), "not-hex"); err == nil {
		t.Error("expected an error for a malformed key")
	}
	if _, err := NewSponsorWithKey(addr, nil, key); err == nil {
		t.Error("expected an error for a nil chain id")
	}
	if _, err := NewSponsorWithKey(addr, big.NewInt(0), key); err == nil {
		t.Error("expected an error for chain id 0")
	}
	if _, err := NewSponsorWithKey(addr, big.NewInt(143), nil); err == nil {
		t.Error("expected an error for a nil key")
	}

	// The round trip config actually uses.
	hex := common.Bytes2Hex(crypto.FromECDSA(key))
	if _, err := NewSponsor(addr, big.NewInt(143), "0x"+hex); err != nil {
		t.Errorf("hex constructor should accept a 0x-prefixed key: %v", err)
	}
}

// The digest commits to the chain and the paymaster, so an approval minted for
// testnet is worthless on mainnet and vice versa.
func TestApprovalHashIsBoundToChainAndPaymaster(t *testing.T) {
	v := loadVector(t)
	op := fixtureOp(t, v)
	validUntil := mustBig(t, v.ValidUntil).Uint64()
	validAfter := mustBig(t, v.ValidAfter).Uint64()
	maxCost := mustBig(t, v.MaxCost)

	base := fixtureSponsor(t, v)
	want, err := base.ApprovalHash(op, validUntil, validAfter, maxCost)
	if err != nil {
		t.Fatal(err)
	}

	otherChain := fixtureSponsor(t, v)
	// Derived from the fixture rather than a literal, so it cannot silently
	// collide with whatever chain the vector is pinned to.
	otherChain.ChainID = new(big.Int).Add(mustBig(t, v.ChainID), big.NewInt(1))
	if got, _ := otherChain.ApprovalHash(op, validUntil, validAfter, maxCost); got == want {
		t.Error("hash must change with the chain id")
	}

	otherPaymaster := fixtureSponsor(t, v)
	otherPaymaster.Address = common.HexToAddress("0x00000000000000000000000000000000000000ff")
	if got, _ := otherPaymaster.ApprovalHash(op, validUntil, validAfter, maxCost); got == want {
		t.Error("hash must change with the paymaster address")
	}
}

// The approval covers the gas fields, so it cannot be lifted onto a more
// expensive operation.
func TestApprovalHashCoversGasParameters(t *testing.T) {
	v := loadVector(t)
	s := fixtureSponsor(t, v)
	op := fixtureOp(t, v)
	validUntil := mustBig(t, v.ValidUntil).Uint64()
	validAfter := mustBig(t, v.ValidAfter).Uint64()
	maxCost := mustBig(t, v.MaxCost)

	want, err := s.ApprovalHash(op, validUntil, validAfter, maxCost)
	if err != nil {
		t.Fatal(err)
	}

	op.MaxFeePerGas = new(big.Int).Add(op.MaxFeePerGas, big.NewInt(1))
	if got, _ := s.ApprovalHash(op, validUntil, validAfter, maxCost); got == want {
		t.Fatal("raising maxFeePerGas must invalidate the approval")
	}
}
