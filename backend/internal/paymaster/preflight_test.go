package paymaster

import (
	"context"
	"errors"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

type fakeCaller struct {
	out     []byte
	err     error
	lastTo  string
	lastSig string
}

func (f *fakeCaller) Call(_ context.Context, to, data string) ([]byte, error) {
	f.lastTo, f.lastSig = to, data
	return f.out, f.err
}

// The signer() selector must be derived, not remembered.
func TestSelectorIsDerivedFromTheSignature(t *testing.T) {
	if got := selector("signer()"); got != "0x238ac933" {
		t.Fatalf("signer() selector = %s, want 0x238ac933", got)
	}
}

func word(a common.Address) []byte {
	out := make([]byte, 32)
	copy(out[12:], a[:])
	return out
}

func newSponsor(t *testing.T, addr common.Address) *Sponsor {
	t.Helper()
	s, err := NewSponsorWithKey(addr, big.NewInt(10143), testKey(t))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestVerifyDeploymentAcceptsAMatchingSigner(t *testing.T) {
	addr := common.HexToAddress("0xb1")
	s := newSponsor(t, addr)
	c := &fakeCaller{out: word(s.SignerAddress())}

	if err := s.VerifyDeployment(context.Background(), c); err != nil {
		t.Fatalf("expected a match: %v", err)
	}
	if c.lastTo != addr.Hex() {
		t.Errorf("called %s, want %s", c.lastTo, addr.Hex())
	}
	if c.lastSig != "0x238ac933" {
		t.Errorf("called selector %s", c.lastSig)
	}
}

// The failure this exists to catch, and the message that has to explain it.
func TestVerifyDeploymentRejectsAMismatchedSigner(t *testing.T) {
	s := newSponsor(t, common.HexToAddress("0xb1"))
	other := common.HexToAddress("0xDEAD")
	c := &fakeCaller{out: word(other)}

	err := s.VerifyDeployment(context.Background(), c)
	if err == nil {
		t.Fatal("expected a mismatch error")
	}
	for _, want := range []string{other.Hex(), s.SignerAddress().Hex(), "rotateSigner"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should mention %q: %v", want, err)
		}
	}
}

// eth_call to an address with no code returns empty rather than reverting, so
// "nothing deployed" must not read as "bad answer".
func TestVerifyDeploymentDetectsNothingDeployed(t *testing.T) {
	s := newSponsor(t, common.HexToAddress("0xb1"))
	c := &fakeCaller{out: nil}

	err := s.VerifyDeployment(context.Background(), c)
	if err == nil {
		t.Fatal("expected an error for an empty return")
	}
	if !strings.Contains(err.Error(), "deployed") {
		t.Errorf("error should say nothing is deployed: %v", err)
	}
}

func TestVerifyDeploymentSurfacesCallErrors(t *testing.T) {
	s := newSponsor(t, common.HexToAddress("0xb1"))
	boom := errors.New("rpc exploded")
	c := &fakeCaller{err: boom}

	err := s.VerifyDeployment(context.Background(), c)
	if !errors.Is(err, boom) {
		t.Fatalf("underlying error must stay wrapped, got %v", err)
	}
}

func TestVerifyDeploymentRejectsUnsetInputs(t *testing.T) {
	s := newSponsor(t, common.HexToAddress("0xb1"))
	if err := s.VerifyDeployment(context.Background(), nil); err == nil {
		t.Error("expected an error for a nil caller")
	}

	unset := newSponsor(t, common.Address{})
	if err := unset.VerifyDeployment(context.Background(), &fakeCaller{out: make([]byte, 32)}); err == nil {
		t.Error("expected an error for an unset paymaster address")
	}
}
