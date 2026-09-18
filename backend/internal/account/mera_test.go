package account

import (
	"crypto/ecdsa"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

func mustKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return key
}

// eip191Sign signs exactly what SimpleAccount checks on-chain: the
// EIP-191-prefixed userOpHash, not the raw hash. Independent of
// meraEthSignedHash so the test does not just check the function against
// itself.
func eip191Sign(t *testing.T, key *ecdsa.PrivateKey, userOpHash common.Hash) []byte {
	t.Helper()
	prefix := []byte("\x19Ethereum Signed Message:\n32")
	digest := crypto.Keccak256Hash(prefix, userOpHash[:])
	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	// crypto.Sign already returns v in {0,1} — test the 27/28 wallet
	// convention too, since that is what a real mobile signer produces.
	sig[64] += 27
	return sig
}

func TestVerifyMeraSignature_AcceptsAGenuineSignature(t *testing.T) {
	key := mustKey(t)
	owner := crypto.PubkeyToAddress(key.PublicKey)
	userOpHash := common.HexToHash("0x1122334455667788112233445566778811223344556677881122334455667788")

	sig := eip191Sign(t, key, userOpHash)
	if err := VerifyMeraSignature(userOpHash, sig, owner); err != nil {
		t.Fatalf("expected valid signature to verify, got %v", err)
	}
}

func TestVerifyMeraSignature_RejectsTheWrongOwner(t *testing.T) {
	key := mustKey(t)
	other := mustKey(t)
	userOpHash := common.HexToHash("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")

	sig := eip191Sign(t, key, userOpHash)
	wrongOwner := crypto.PubkeyToAddress(other.PublicKey)
	if err := VerifyMeraSignature(userOpHash, sig, wrongOwner); err == nil {
		t.Fatal("expected verification to fail against a different owner")
	}
}

func TestVerifyMeraSignature_RejectsAShortSignature(t *testing.T) {
	err := VerifyMeraSignature(common.Hash{}, make([]byte, 64), common.Address{})
	if err != ErrMeraSignatureLength {
		t.Fatalf("expected ErrMeraSignatureLength, got %v", err)
	}
}

func TestVerifyMeraSignature_RejectsASignatureOverADifferentHash(t *testing.T) {
	key := mustKey(t)
	owner := crypto.PubkeyToAddress(key.PublicKey)
	signed := common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111")
	other := common.HexToHash("0x2222222222222222222222222222222222222222222222222222222222222222")

	sig := eip191Sign(t, key, signed)
	if err := VerifyMeraSignature(other, sig, owner); err == nil {
		t.Fatal("expected verification to fail for a signature over a different hash")
	}
}

func TestEncodeCreateMeraAccount_RejectsTheZeroOwner(t *testing.T) {
	if _, err := EncodeCreateMeraAccount(common.Address{}, big.NewInt(0)); err == nil {
		t.Fatal("expected the zero address to be rejected")
	}
}

func TestInitCodeMera_PrependsTheFactoryAddress(t *testing.T) {
	factory := common.HexToAddress("0x1Bf83Abaed15F682F3EcE3527BdBd8dCf5175bE5")
	owner := common.HexToAddress("0x000000000000000000000000000000000000dE")

	code, err := InitCodeMera(factory, owner, big.NewInt(0))
	if err != nil {
		t.Fatalf("InitCodeMera: %v", err)
	}
	if len(code) < 20 {
		t.Fatalf("initCode too short: %d bytes", len(code))
	}
	if got := common.BytesToAddress(code[:20]); got != factory {
		t.Fatalf("initCode must start with the factory address: got %s, want %s", got, factory)
	}

	// The rest is the createAccount(address,uint256) call — selector-first,
	// same convention EncodeCreateMeraAccount already builds and tests
	// indirectly via the round trip.
	call, err := EncodeCreateMeraAccount(owner, big.NewInt(0))
	if err != nil {
		t.Fatalf("EncodeCreateMeraAccount: %v", err)
	}
	if string(code[20:]) != string(call) {
		t.Fatal("initCode's call data must match EncodeCreateMeraAccount exactly")
	}
}
