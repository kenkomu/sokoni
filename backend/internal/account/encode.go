// Package account encodes calls to SokoniAccount and SokoniAccountFactory.
//
// This is the other half of the client/server split: the phone produces a
// WebAuthn assertion and nothing else, and everything that has to be
// ABI-shaped happens here. In particular `EncodeSignature` turns an assertion
// into the bytes `validateUserOp` decodes, which is the actual join between the
// authenticator and the account.
//
// Every encoding in this file is pinned against the compiler's own output by
// contracts/test/fixtures/userop_vector.json. That matters more than usual:
// a wrong encoding is not a crash, it is a bundler returning `AA23 reverted`,
// which names the stage and nothing else.
package account

import (
	"encoding/hex"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// Passkey is a P-256 public key: the account's owner on-chain.
type Passkey struct {
	X *big.Int
	Y *big.Int
}

// Assertion is what the authenticator produced, in the pieces the contract
// needs. The offsets say where to look inside clientDataJSON; the signature
// covers the whole of it, so a wrong offset can only fail, never smuggle.
type Assertion struct {
	AuthenticatorData []byte
	ClientDataJSON    string
	ChallengeIndex    uint64
	TypeIndex         uint64
	R                 *big.Int
	S                 *big.Int
}

// selector is the first four bytes of keccak256 of a function signature.
// Derived rather than pasted: a hand-copied selector is a silent misdial.
func selector(sig string) []byte { return crypto.Keccak256([]byte(sig))[:4] }

// Solidity type descriptions, kept next to the signatures they belong to so the
// two cannot drift apart.
var (
	passkeyComponents = []abi.ArgumentMarshaling{
		{Name: "x", Type: "uint256"},
		{Name: "y", Type: "uint256"},
	}
	authComponents = []abi.ArgumentMarshaling{
		{Name: "authenticatorData", Type: "bytes"},
		{Name: "clientDataJSON", Type: "string"},
		{Name: "challengeIndex", Type: "uint256"},
		{Name: "typeIndex", Type: "uint256"},
		{Name: "r", Type: "uint256"},
		{Name: "s", Type: "uint256"},
	}
)

func mustType(t string, components []abi.ArgumentMarshaling) abi.Type {
	typ, err := abi.NewType(t, "", components)
	if err != nil {
		// These are compile-time constants in everything but name; a failure
		// here is a typo in this file, not a runtime condition.
		panic(fmt.Sprintf("account: bad abi type %q: %v", t, err))
	}
	return typ
}

// -------------------------------------------------------------- signature

type abiAuth struct {
	AuthenticatorData []byte   `abi:"authenticatorData"`
	ClientDataJSON    string   `abi:"clientDataJSON"`
	ChallengeIndex    *big.Int `abi:"challengeIndex"`
	TypeIndex         *big.Int `abi:"typeIndex"`
	R                 *big.Int `abi:"r"`
	S                 *big.Int `abi:"s"`
}

type abiPasskeySignature struct {
	OwnerIndex *big.Int `abi:"ownerIndex"`
	Auth       abiAuth  `abi:"auth"`
}

var signatureArgs = abi.Arguments{{Type: mustType("tuple", []abi.ArgumentMarshaling{
	{Name: "ownerIndex", Type: "uint256"},
	{Name: "auth", Type: "tuple", Components: authComponents},
})}}

// EncodeSignature produces the `signature` field of a user operation.
//
// `ownerIndex` says which registered credential signed, so validation does not
// have to try every key in turn. It must match the account's owner slot — a
// removed owner is zeroed rather than shifted, so indices stay stable for the
// life of the account.
func EncodeSignature(ownerIndex uint64, a Assertion) ([]byte, error) {
	if a.R == nil || a.S == nil {
		return nil, fmt.Errorf("assertion is missing r or s")
	}
	if len(a.AuthenticatorData) < 37 {
		return nil, fmt.Errorf("authenticatorData is %d bytes, minimum is 37", len(a.AuthenticatorData))
	}
	if a.ClientDataJSON == "" {
		return nil, fmt.Errorf("clientDataJSON is empty")
	}
	return signatureArgs.Pack(abiPasskeySignature{
		OwnerIndex: new(big.Int).SetUint64(ownerIndex),
		Auth: abiAuth{
			AuthenticatorData: a.AuthenticatorData,
			ClientDataJSON:    a.ClientDataJSON,
			ChallengeIndex:    new(big.Int).SetUint64(a.ChallengeIndex),
			TypeIndex:         new(big.Int).SetUint64(a.TypeIndex),
			R:                 a.R,
			S:                 a.S,
		},
	})
}

// ---------------------------------------------------------------- execute

var executeArgs = abi.Arguments{
	{Type: mustType("address", nil)},
	{Type: mustType("uint256", nil)},
	{Type: mustType("bytes", nil)},
}

// EncodeExecute builds callData for a single call from the account.
func EncodeExecute(target common.Address, value *big.Int, data []byte) ([]byte, error) {
	if value == nil {
		value = new(big.Int)
	}
	if value.Sign() < 0 {
		return nil, fmt.Errorf("value must be non-negative")
	}
	args, err := executeArgs.Pack(target, value, data)
	if err != nil {
		return nil, err
	}
	return append(selector("execute(address,uint256,bytes)"), args...), nil
}

var executeBatchArgs = abi.Arguments{
	{Type: mustType("address[]", nil)},
	{Type: mustType("uint256[]", nil)},
	{Type: mustType("bytes[]", nil)},
}

// EncodeExecuteBatch builds callData for several calls in one UserOperation
// -- e.g. an ERC-20 approve immediately followed by the call that spends it,
// which must land in the same operation or the approval is a second,
// separately-signed step. Matches SimpleAccount.executeBatch (and
// SokoniAccount's, same signature) exactly, not a Sokoni-specific shape:
// `executeBatch(address[] dest, uint256[] value, bytes[] func)`.
func EncodeExecuteBatch(targets []common.Address, values []*big.Int, data [][]byte) ([]byte, error) {
	if len(targets) != len(values) || len(targets) != len(data) {
		return nil, fmt.Errorf("executeBatch: targets/values/data must be the same length, got %d/%d/%d",
			len(targets), len(values), len(data))
	}
	if len(targets) == 0 {
		return nil, fmt.Errorf("executeBatch: at least one call is required")
	}
	for _, v := range values {
		if v != nil && v.Sign() < 0 {
			return nil, fmt.Errorf("value must be non-negative")
		}
	}
	normalized := make([]*big.Int, len(values))
	for i, v := range values {
		if v == nil {
			v = new(big.Int)
		}
		normalized[i] = v
	}
	args, err := executeBatchArgs.Pack(targets, normalized, data)
	if err != nil {
		return nil, err
	}
	return append(selector("executeBatch(address[],uint256[],bytes[])"), args...), nil
}

// ---------------------------------------------------------------- factory

type abiPasskey struct {
	X *big.Int `abi:"x"`
	Y *big.Int `abi:"y"`
}

var factoryArgs = abi.Arguments{
	{Type: mustType("bytes32", nil)},
	{Type: mustType("tuple[]", passkeyComponents)},
	{Type: mustType("uint256", nil)},
}

func packFactoryCall(sig string, rpIDHash [32]byte, owners []Passkey, salt *big.Int) ([]byte, error) {
	if len(owners) == 0 {
		return nil, fmt.Errorf("an account needs at least one owner")
	}
	packed := make([]abiPasskey, len(owners))
	for i, o := range owners {
		if o.X == nil || o.Y == nil {
			return nil, fmt.Errorf("owner %d has a nil coordinate", i)
		}
		packed[i] = abiPasskey{X: o.X, Y: o.Y}
	}
	if salt == nil {
		salt = new(big.Int)
	}
	args, err := factoryArgs.Pack(rpIDHash, packed, salt)
	if err != nil {
		return nil, err
	}
	return append(selector(sig), args...), nil
}

const (
	createAccountSig = "createAccount(bytes32,(uint256,uint256)[],uint256)"
	getAddressSig    = "getAddress(bytes32,(uint256,uint256)[],uint256)"
)

// EncodeCreateAccount builds the factory call that deploys an account.
func EncodeCreateAccount(rpIDHash [32]byte, owners []Passkey, salt *big.Int) ([]byte, error) {
	return packFactoryCall(createAccountSig, rpIDHash, owners, salt)
}

// EncodeGetAddress builds the eth_call that asks the factory where an account
// *would* be deployed.
//
// Worth asking the factory rather than recomputing CREATE2 locally: the salt
// commits to the owner set, and getting that derivation subtly wrong produces a
// plausible address that nothing will ever deploy to.
func EncodeGetAddress(rpIDHash [32]byte, owners []Passkey, salt *big.Int) ([]byte, error) {
	return packFactoryCall(getAddressSig, rpIDHash, owners, salt)
}

// InitCode is the factory address followed by the call that deploys the
// account, as ERC-4337 expects it on a first operation.
//
// Send it only on the first operation. Once the account exists, initCode must
// be empty or the EntryPoint rejects the operation (AA10).
func InitCode(factory common.Address, rpIDHash [32]byte, owners []Passkey, salt *big.Int) ([]byte, error) {
	data, err := EncodeCreateAccount(rpIDHash, owners, salt)
	if err != nil {
		return nil, err
	}
	return append(factory.Bytes(), data...), nil
}

// -------------------------------------------------------------- entrypoint

var nonceArgs = abi.Arguments{
	{Type: mustType("address", nil)},
	{Type: mustType("uint192", nil)},
}

// EncodeGetNonce builds the EntryPoint eth_call for an account's next nonce.
//
// The `key` is a 192-bit nonce space. Different keys advance independently,
// which is how an account can have several operations in flight without them
// having to land in order — worth knowing exists, though Phase 1 uses key 0.
func EncodeGetNonce(sender common.Address, key *big.Int) ([]byte, error) {
	if key == nil {
		key = new(big.Int)
	}
	if key.Sign() < 0 || key.BitLen() > 192 {
		return nil, fmt.Errorf("nonce key must fit in uint192")
	}
	args, err := nonceArgs.Pack(sender, key)
	if err != nil {
		return nil, err
	}
	return append(selector("getNonce(address,uint192)"), args...), nil
}

// Hex renders calldata the way an eth_call wants it.
func Hex(b []byte) string { return "0x" + hex.EncodeToString(b) }
