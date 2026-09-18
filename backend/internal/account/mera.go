// Mera path (Option 2): an account owned by a plain ECDSA key derived on the
// phone from a passkey's WebAuthn PRF output, instead of a P-256 WebAuthn
// credential verified through Monad's precompile.
//
// Deliberately parallel to encode.go/verify.go, not a modification of them:
// SokoniAccount/SokoniAccountFactory (the P-256 path) are untouched. This
// file targets eth-infinitism's own `SimpleAccount`/`SimpleAccountFactory`
// (vendored unmodified at contracts/lib/account-abstraction/contracts/
// samples/ — see contracts/script/DeployMeraAccountFactory.s.sol for why
// nothing here needed a new Solidity contract). SokoniPaymaster sponsors
// this path with zero changes: it never calls into the account, only reads
// userOp fields — proven in contracts/test/MeraAccount.t.sol.
package account

import (
	"errors"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

var (
	ErrMeraSignatureLength = errors.New("mera signature must be exactly 65 bytes (r, s, v)")
	ErrMeraBadSignature    = errors.New("mera signature does not recover to the expected owner")
)

// ---------------------------------------------------------------- factory

var meraFactoryArgs = abi.Arguments{
	{Type: mustType("address", nil)},
	{Type: mustType("uint256", nil)},
}

func packMeraFactoryCall(sig string, owner common.Address, salt *big.Int) ([]byte, error) {
	if owner == (common.Address{}) {
		return nil, fmt.Errorf("owner must not be the zero address")
	}
	if salt == nil {
		salt = new(big.Int)
	}
	args, err := meraFactoryArgs.Pack(owner, salt)
	if err != nil {
		return nil, err
	}
	return append(selector(sig), args...), nil
}

const (
	createMeraAccountSig = "createAccount(address,uint256)"
	getMeraAddressSig    = "getAddress(address,uint256)"
)

// EncodeCreateMeraAccount builds the factory call that deploys a
// SimpleAccount owned by owner.
func EncodeCreateMeraAccount(owner common.Address, salt *big.Int) ([]byte, error) {
	return packMeraFactoryCall(createMeraAccountSig, owner, salt)
}

// EncodeGetMeraAddress builds the eth_call that asks the factory where such
// an account would be (or already is) deployed.
func EncodeGetMeraAddress(owner common.Address, salt *big.Int) ([]byte, error) {
	return packMeraFactoryCall(getMeraAddressSig, owner, salt)
}

// InitCodeMera is the factory address followed by the call that deploys the
// account, as ERC-4337 expects it on a first operation.
func InitCodeMera(factory, owner common.Address, salt *big.Int) ([]byte, error) {
	data, err := EncodeCreateMeraAccount(owner, salt)
	if err != nil {
		return nil, err
	}
	return append(factory.Bytes(), data...), nil
}

// ------------------------------------------------------------- signature

// EIP-191 personal-sign prefix, matching what SimpleAccount's
// `MessageHashUtils.toEthSignedMessageHash` applies on-chain before
// `ECDSA.recover`. The phone must sign this, not the raw userOpHash.
func meraEthSignedHash(userOpHash common.Hash) common.Hash {
	prefix := fmt.Sprintf("\x19Ethereum Signed Message:\n%d", len(userOpHash))
	return crypto.Keccak256Hash([]byte(prefix), userOpHash[:])
}

// VerifyMeraSignature checks a signature exactly as SimpleAccount will,
// before the bundler ever sees it — the same reasoning as VerifyAssertion
// for the P-256 path (ERC-7562 paymaster reputation; see that function's
// doc comment).
func VerifyMeraSignature(userOpHash common.Hash, sig []byte, owner common.Address) error {
	if len(sig) != 65 {
		return ErrMeraSignatureLength
	}
	// go-ethereum's Ecrecover wants v in {0,1}; Ethereum wallets (and the
	// EIP-191 convention SimpleAccount checks against) produce v in {27,28}.
	normalized := append([]byte(nil), sig...)
	if normalized[64] >= 27 {
		normalized[64] -= 27
	}

	hash := meraEthSignedHash(userOpHash)
	pub, err := crypto.SigToPub(hash[:], normalized)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrMeraBadSignature, err)
	}
	if crypto.PubkeyToAddress(*pub) != owner {
		return ErrMeraBadSignature
	}
	return nil
}

// EncodeMeraSignature returns the userOp.signature field: SimpleAccount
// passes it directly to ECDSA.recover, so unlike the P-256 path's
// PasskeySignature struct, this is the raw 65 bytes with no ABI wrapping.
func EncodeMeraSignature(sig []byte) ([]byte, error) {
	if len(sig) != 65 {
		return nil, ErrMeraSignatureLength
	}
	return sig, nil
}
