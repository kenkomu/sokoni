package account

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"math/big"
)

// Verification mirrors WebAuthn.verify in contracts/src/lib/WebAuthn.sol, check
// for check, so the backend can refuse a bad assertion before it costs anything.
//
// The contract would reject it anyway, so this is not the security boundary. It
// exists because of what happens before the contract gets a say: bundlers
// simulate validation, and ERC-7562 tracks reputation per paymaster. A paymaster
// whose sponsored operations keep failing validation is throttled and then
// banned (-32504) — for every user, not just the one who sent the bad signature.
// Checking here turns a broken client or a stale challenge into one 400 rather
// than a strike against the paymaster.

var (
	ErrAuthenticatorDataShort = errors.New("authenticatorData is shorter than 37 bytes")
	ErrWrongRelyingParty      = errors.New("assertion is bound to a different relying party")
	ErrUserNotPresent         = errors.New("authenticator did not assert user presence")
	ErrUserNotVerified        = errors.New("authenticator did not assert user verification")
	ErrWrongType              = errors.New(`clientDataJSON does not carry "type":"webauthn.get" at typeIndex`)
	ErrWrongChallenge         = errors.New("clientDataJSON does not carry this challenge at challengeIndex")
	ErrScalarOutOfRange       = errors.New("signature scalar is out of range")
	ErrHighS                  = errors.New("signature s is in the high half; the client must normalise it")
	ErrBadSignature           = errors.New("P-256 signature does not verify against this key")
	ErrKeyNotOnCurve          = errors.New("public key is not a point on P-256")
)

var (
	p256      = elliptic.P256()
	p256N     = p256.Params().N
	p256HalfN = new(big.Int).Rsh(p256N, 1)
)

// authenticatorData flag bits, WebAuthn Level 3 §6.1.
const (
	flagUserPresent  = 0x01
	flagUserVerified = 0x04
)

// PublicKey validates the owner as a point on P-256.
//
// Worth calling at registration, not only at verification: an off-curve key
// yields a perfectly valid-looking account address that no signature can ever
// authorise. Showing a user that address and letting them fund it would be
// losing their money in advance.
func (p Passkey) PublicKey() (*ecdsa.PublicKey, error) {
	if p.X == nil || p.Y == nil || p.X.Sign() < 0 || p.Y.Sign() < 0 ||
		p.X.BitLen() > 256 || p.Y.BitLen() > 256 {
		return nil, ErrKeyNotOnCurve
	}
	raw := make([]byte, 65)
	raw[0] = 0x04 // uncompressed point
	p.X.FillBytes(raw[1:33])
	p.Y.FillBytes(raw[33:65])
	pub, err := ecdsa.ParseUncompressedPublicKey(p256, raw)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrKeyNotOnCurve, err)
	}
	return pub, nil
}

// Digest is what the authenticator actually signed:
//
//	sha256( authenticatorData || sha256(clientDataJSON) )
//
// Not the challenge. The challenge appears only inside clientDataJSON.
func Digest(a Assertion) [32]byte {
	clientHash := sha256.Sum256([]byte(a.ClientDataJSON))
	h := sha256.New()
	h.Write(a.AuthenticatorData)
	h.Write(clientHash[:])
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out
}

// VerifyAssertion checks an assertion exactly as SokoniAccount will.
//
// `challenge` is the raw bytes the account passes to WebAuthn.verify — for a
// user operation that is abi.encode(userOpHash), which is the 32 hash bytes
// themselves. A zero rpIDHash skips the relying-party check, as the contract
// does.
func VerifyAssertion(challenge []byte, rpIDHash [32]byte, requireUV bool, a Assertion, owner Passkey) error {
	if len(a.AuthenticatorData) < 37 {
		return ErrAuthenticatorDataShort
	}
	if rpIDHash != ([32]byte{}) && !bytes.Equal(a.AuthenticatorData[:32], rpIDHash[:]) {
		return ErrWrongRelyingParty
	}

	flags := a.AuthenticatorData[32]
	if flags&flagUserPresent == 0 {
		return ErrUserNotPresent
	}
	if requireUV && flags&flagUserVerified == 0 {
		return ErrUserNotVerified
	}

	if !matchesAt(a.ClientDataJSON, a.TypeIndex, `"type":"webauthn.get"`) {
		return ErrWrongType
	}
	want := `"challenge":"` + base64.RawURLEncoding.EncodeToString(challenge) + `"`
	if !matchesAt(a.ClientDataJSON, a.ChallengeIndex, want) {
		return ErrWrongChallenge
	}

	if a.R == nil || a.S == nil ||
		a.R.Sign() <= 0 || a.R.Cmp(p256N) >= 0 ||
		a.S.Sign() <= 0 || a.S.Cmp(p256N) >= 0 {
		return ErrScalarOutOfRange
	}
	// The precompile accepts (r, N-s) too; the contract refuses it, so we do.
	if a.S.Cmp(p256HalfN) > 0 {
		return ErrHighS
	}

	pub, err := owner.PublicKey()
	if err != nil {
		return err
	}
	digest := Digest(a)
	if !ecdsa.Verify(pub, digest[:], a.R, a.S) {
		return ErrBadSignature
	}
	return nil
}

// matchesAt mirrors WebAuthn._matchesAt: needle occurs in subject starting
// exactly at offset. Offsets are client-supplied, so the bounds are checked in
// a form that cannot overflow before anything is sliced.
func matchesAt(subject string, offset uint64, needle string) bool {
	n := uint64(len(subject))
	if offset > n || uint64(len(needle)) > n-offset {
		return false
	}
	return subject[offset:offset+uint64(len(needle))] == needle
}
