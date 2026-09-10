package account

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

// The frozen assertion WebAuthn.t.sol and the Dart tests assert against. Using
// the same one here makes three implementations — Solidity, Dart, Go — answer
// to one set of bytes, which is the only way to know they agree.
const webauthnVectorPath = "../../../contracts/test/fixtures/webauthn_vector.json"

type webauthnVector struct {
	X                 string `json:"x"`
	Y                 string `json:"y"`
	Challenge         string `json:"challenge"`
	ClientDataJSON    string `json:"clientDataJSON"`
	AuthenticatorData string `json:"authenticatorData"`
	Digest            string `json:"digest"`
	R                 string `json:"r"`
	S                 string `json:"s"`
	SHigh             string `json:"sHigh"`
	TypeIndex         uint64 `json:"typeIndex"`
	ChallengeIndex    uint64 `json:"challengeIndex"`
}

func loadWebAuthn(t *testing.T) webauthnVector {
	t.Helper()
	raw, err := os.ReadFile(filepath.Clean(webauthnVectorPath))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var v webauthnVector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return v
}

// hexBig accepts leading zeros, unlike hexutil.DecodeBig — the fixture and the
// phone both zero-pad to 32 bytes.
func hexBig(s string) *big.Int { return new(big.Int).SetBytes(common.FromHex(s)) }

var sokoniRPIDHash = sha256.Sum256([]byte("sokoni.app"))

func frozen(t *testing.T) (Assertion, Passkey, []byte) {
	t.Helper()
	v := loadWebAuthn(t)
	return Assertion{
			AuthenticatorData: common.FromHex(v.AuthenticatorData),
			ClientDataJSON:    v.ClientDataJSON,
			ChallengeIndex:    v.ChallengeIndex,
			TypeIndex:         v.TypeIndex,
			R:                 hexBig(v.R),
			S:                 hexBig(v.S),
		},
		Passkey{X: hexBig(v.X), Y: hexBig(v.Y)},
		common.FromHex(v.Challenge)
}

func TestVerifiesTheFrozenAssertion(t *testing.T) {
	a, owner, challenge := frozen(t)
	if err := VerifyAssertion(challenge, sokoniRPIDHash, true, a, owner); err != nil {
		t.Fatalf("the assertion the contract accepts must verify here too: %v", err)
	}
}

// Pins the digest construction on its own, so a failure says which half broke.
func TestDigestMatchesTheFixture(t *testing.T) {
	a, _, _ := frozen(t)
	got := Digest(a)
	if want := common.HexToHash(loadWebAuthn(t).Digest); common.Hash(got) != want {
		t.Fatalf("digest %x, want %x", got, want)
	}
}

// The finding that shaped P256.verify: the precompile accepts the high-s form,
// so the rule is ours to enforce — here as well as on chain.
func TestRejectsHighS(t *testing.T) {
	a, owner, challenge := frozen(t)
	a.S = hexBig(loadWebAuthn(t).SHigh)
	if err := VerifyAssertion(challenge, sokoniRPIDHash, true, a, owner); !errors.Is(err, ErrHighS) {
		t.Fatalf("got %v, want ErrHighS", err)
	}
}

func TestRejectsWrongChallenge(t *testing.T) {
	a, owner, _ := frozen(t)
	other := sha256.Sum256([]byte("a different operation"))
	if err := VerifyAssertion(other[:], sokoniRPIDHash, true, a, owner); !errors.Is(err, ErrWrongChallenge) {
		t.Fatalf("got %v, want ErrWrongChallenge", err)
	}
}

func TestRejectsWrongRelyingParty(t *testing.T) {
	a, owner, challenge := frozen(t)
	other := sha256.Sum256([]byte("evil.example"))
	if err := VerifyAssertion(challenge, other, true, a, owner); !errors.Is(err, ErrWrongRelyingParty) {
		t.Fatalf("got %v, want ErrWrongRelyingParty", err)
	}
}

// Mirrors the contract: a zero rpIdHash skips the check.
func TestZeroRelyingPartySkipsTheCheck(t *testing.T) {
	a, owner, challenge := frozen(t)
	if err := VerifyAssertion(challenge, [32]byte{}, true, a, owner); err != nil {
		t.Fatalf("zero rpIdHash must skip the check: %v", err)
	}
}

func TestRejectsMissingUserVerification(t *testing.T) {
	a, owner, challenge := frozen(t)
	a.AuthenticatorData = append([]byte(nil), a.AuthenticatorData...)
	a.AuthenticatorData[32] &^= flagUserVerified
	if err := VerifyAssertion(challenge, sokoniRPIDHash, true, a, owner); !errors.Is(err, ErrUserNotVerified) {
		t.Fatalf("got %v, want ErrUserNotVerified", err)
	}
}

func TestRejectsMissingUserPresence(t *testing.T) {
	a, owner, challenge := frozen(t)
	a.AuthenticatorData = append([]byte(nil), a.AuthenticatorData...)
	a.AuthenticatorData[32] &^= flagUserPresent
	if err := VerifyAssertion(challenge, sokoniRPIDHash, false, a, owner); !errors.Is(err, ErrUserNotPresent) {
		t.Fatalf("got %v, want ErrUserNotPresent", err)
	}
}

// A registration assertion must never pass as an authorisation.
func TestRejectsWhenTypeIsNotAtTypeIndex(t *testing.T) {
	a, owner, challenge := frozen(t)
	a.TypeIndex = 0
	if err := VerifyAssertion(challenge, sokoniRPIDHash, true, a, owner); !errors.Is(err, ErrWrongType) {
		t.Fatalf("got %v, want ErrWrongType", err)
	}
}

func TestRejectsAnotherKey(t *testing.T) {
	a, _, challenge := frozen(t)
	// The generator point is on the curve but is not this credential's key.
	g := Passkey{X: p256.Params().Gx, Y: p256.Params().Gy}
	if err := VerifyAssertion(challenge, sokoniRPIDHash, true, a, g); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("got %v, want ErrBadSignature", err)
	}
}

func TestRejectsOffCurveKey(t *testing.T) {
	a, _, challenge := frozen(t)
	bad := Passkey{X: big.NewInt(1), Y: big.NewInt(1)}
	if err := VerifyAssertion(challenge, sokoniRPIDHash, true, a, bad); !errors.Is(err, ErrKeyNotOnCurve) {
		t.Fatalf("got %v, want ErrKeyNotOnCurve", err)
	}
	if _, err := bad.PublicKey(); !errors.Is(err, ErrKeyNotOnCurve) {
		t.Fatalf("PublicKey must reject it too, got %v", err)
	}
}

func TestRejectsDegenerateScalars(t *testing.T) {
	_, owner, challenge := frozen(t)
	for name, mutate := range map[string]func(*Assertion){
		"r = 0": func(a *Assertion) { a.R = new(big.Int) },
		"s = 0": func(a *Assertion) { a.S = new(big.Int) },
		"r = N": func(a *Assertion) { a.R = new(big.Int).Set(p256N) },
		"s = N": func(a *Assertion) { a.S = new(big.Int).Set(p256N) },
		"nil r": func(a *Assertion) { a.R = nil },
		"nil s": func(a *Assertion) { a.S = nil },
	} {
		t.Run(name, func(t *testing.T) {
			a, _, _ := frozen(t)
			mutate(&a)
			if err := VerifyAssertion(challenge, sokoniRPIDHash, true, a, owner); !errors.Is(err, ErrScalarOutOfRange) {
				t.Fatalf("got %v, want ErrScalarOutOfRange", err)
			}
		})
	}
}

// Offsets are attacker-supplied. Nothing may panic, wrap or read out of bounds.
func TestHostileOffsetsNeverPanic(t *testing.T) {
	_, owner, challenge := frozen(t)
	for _, off := range []uint64{0, 1, 22, 24, 1 << 31, math.MaxUint32, math.MaxUint64 - 1, math.MaxUint64} {
		a, _, _ := frozen(t)
		a.ChallengeIndex, a.TypeIndex = off, off
		// Must return, not panic. Offsets that happen to be right are fine too.
		_ = VerifyAssertion(challenge, sokoniRPIDHash, true, a, owner)
	}
}

func TestShortAuthenticatorData(t *testing.T) {
	a, owner, challenge := frozen(t)
	a.AuthenticatorData = a.AuthenticatorData[:36]
	if err := VerifyAssertion(challenge, sokoniRPIDHash, true, a, owner); !errors.Is(err, ErrAuthenticatorDataShort) {
		t.Fatalf("got %v, want ErrAuthenticatorDataShort", err)
	}
}
