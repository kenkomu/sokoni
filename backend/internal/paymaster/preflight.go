package paymaster

import (
	"context"
	"encoding/hex"
	"fmt"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// Caller is the slice of a chain client this package needs. Narrow on purpose,
// so preflight can be tested without an RPC endpoint.
type Caller interface {
	Call(ctx context.Context, to string, data string) ([]byte, error)
}

// selector is the first four bytes of keccak256 of a function signature.
// Computed rather than pasted: a hand-copied selector is a silent misdial.
func selector(sig string) string {
	return "0x" + hex.EncodeToString(crypto.Keccak256([]byte(sig))[:4])
}

// VerifyDeployment checks that the paymaster on chain agrees with this Sponsor
// before we sign anything against it.
//
// Worth doing at boot because the failure it catches is otherwise invisible and
// total: if the deployed contract holds a different signer, every sponsored
// operation is rejected during validation, and the only symptom is a bundler
// returning "AA34 signature error" for reasons that look like our signing code.
// Two lines of eth_call at startup beat an afternoon of that.
//
// It does not check the deposit or the stake — those are live values that go
// stale, and belong on a metric with an alert rather than in a boot gate.
func (s *Sponsor) VerifyDeployment(ctx context.Context, c Caller) error {
	if c == nil {
		return fmt.Errorf("nil caller")
	}
	if s.Address == (common.Address{}) {
		return fmt.Errorf("paymaster address is unset")
	}

	out, err := c.Call(ctx, s.Address.Hex(), selector("signer()"))
	if err != nil {
		return fmt.Errorf("read paymaster signer: %w", err)
	}
	// A call to an address with no code returns empty rather than reverting, so
	// a short result means "nothing deployed here", not "bad answer".
	if len(out) != 32 {
		return fmt.Errorf(
			"paymaster at %s returned %d bytes for signer(); is anything deployed there?",
			s.Address, len(out))
	}

	onChain := common.BytesToAddress(out[12:])
	if onChain != s.SignerAddress() {
		return fmt.Errorf(
			"paymaster %s is registered to signer %s, but this backend signs as %s — "+
				"every sponsorship would be rejected; rotateSigner or fix PAYMASTER_SIGNER_KEY",
			s.Address, onChain, s.SignerAddress())
	}
	return nil
}
