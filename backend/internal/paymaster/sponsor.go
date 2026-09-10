// Package paymaster signs gas sponsorship approvals for SokoniPaymaster.
//
// The contract deliberately holds no policy. It only proves that this key
// approved this operation at these gas parameters. Deciding *whether* to
// sponsor — daily caps, per-user limits, which calls are eligible, whether the
// account is in good standing — belongs to the caller, where it can read
// Postgres and Redis and be changed without a deployment.
//
// The signing key is the one secret in this system that can spend money
// (specifically, the paymaster's EntryPoint deposit). It is bounded rather than
// trusted: every approval names an explicit maxCost and a validity window, and
// the on-chain signer is rotatable, so a leak is contained by one transaction
// rather than by redeploying and re-staking.
package paymaster

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/kenkomu/sokoni/backend/internal/userop"
)

// Byte offsets within paymasterAndData. The first 52 are fixed by ERC-4337;
// everything after is SokoniPaymaster's own layout and must match the constants
// in SokoniPaymaster.sol.
const (
	validUntilOffset = 52
	validAfterOffset = 58
	maxCostOffset    = 64
	signatureOffset  = 80
	// DataLength is the exact length SokoniPaymaster accepts. Anything else is
	// rejected on-chain as a malformed approval.
	DataLength = 145
)

// Sponsor issues approvals against one deployed SokoniPaymaster.
type Sponsor struct {
	// Address of the deployed paymaster. Bound into every signature, so an
	// approval cannot be presented to a different paymaster.
	Address common.Address
	// ChainID, likewise bound in, so a testnet approval is useless on mainnet.
	ChainID *big.Int

	// Gas the EntryPoint may spend inside the paymaster's own validation.
	// Hardcoded rather than estimated: Monad charges on the gas limit rather
	// than the amount used, so a loose estimate is a cost paid on every op.
	VerificationGasLimit *big.Int
	// Zero. `_validatePaymasterUserOp` returns an empty context, so the
	// EntryPoint never calls postOp.
	PostOpGasLimit *big.Int

	key *ecdsa.PrivateKey
}

// NewSponsor builds a Sponsor from a hex-encoded secp256k1 private key, as it
// arrives from configuration.
func NewSponsor(address common.Address, chainID *big.Int, hexKey string) (*Sponsor, error) {
	key, err := crypto.HexToECDSA(trim0x(hexKey))
	if err != nil {
		return nil, fmt.Errorf("parse sponsor key: %w", err)
	}
	return NewSponsorWithKey(address, chainID, key)
}

// NewSponsorWithKey builds a Sponsor from an already-loaded key.
//
// Preferred wherever the key does not have to exist as a string: a hex private
// key in a config value is a secret that leaks into process listings, crash
// dumps and logs. This is also the seam to put a KMS or HSM behind later.
func NewSponsorWithKey(address common.Address, chainID *big.Int, key *ecdsa.PrivateKey) (*Sponsor, error) {
	if chainID == nil || chainID.Sign() <= 0 {
		return nil, fmt.Errorf("chain id must be positive")
	}
	if key == nil {
		return nil, fmt.Errorf("signing key is nil")
	}
	return &Sponsor{
		Address:              address,
		ChainID:              chainID,
		VerificationGasLimit: big.NewInt(120_000),
		PostOpGasLimit:       big.NewInt(0),
		key:                  key,
	}, nil
}

func trim0x(s string) string {
	if len(s) >= 2 && (s[:2] == "0x" || s[:2] == "0X") {
		return s[2:]
	}
	return s
}

// SignerAddress is the address the deployed paymaster must have registered.
// Check it at boot: a mismatch means every sponsorship will be rejected
// on-chain, and it is far cheaper to find that out at startup.
func (s *Sponsor) SignerAddress() common.Address {
	return crypto.PubkeyToAddress(s.key.PublicKey)
}

// gasLimitsWord is paymasterAndData[20:52] — the two paymaster gas limits as
// one 32-byte word, which is how the approval digest reads them.
func (s *Sponsor) gasLimitsWord() ([32]byte, error) {
	var out [32]byte
	if s.VerificationGasLimit == nil || s.PostOpGasLimit == nil {
		return out, fmt.Errorf("paymaster gas limits are not set")
	}
	max128 := new(big.Int).Lsh(big.NewInt(1), 128)
	if s.VerificationGasLimit.Cmp(max128) >= 0 || s.PostOpGasLimit.Cmp(max128) >= 0 {
		return out, fmt.Errorf("paymaster gas limit exceeds uint128")
	}
	s.VerificationGasLimit.FillBytes(out[0:16])
	s.PostOpGasLimit.FillBytes(out[16:32])
	return out, nil
}

// ApprovalHash reproduces SokoniPaymaster.approvalHash.
//
// Every field that determines what the sponsorship costs, plus who it is for.
// Excludes op.Signature, because the passkey signs after we approve — the
// account verifies that half, we verify the gas half.
func (s *Sponsor) ApprovalHash(op *userop.UserOperation, validUntil, validAfter uint64, maxCost *big.Int) (common.Hash, error) {
	accountGasLimits, err := op.AccountGasLimits()
	if err != nil {
		return common.Hash{}, fmt.Errorf("accountGasLimits: %w", err)
	}
	gasFees, err := op.GasFees()
	if err != nil {
		return common.Hash{}, fmt.Errorf("gasFees: %w", err)
	}
	gasLimits, err := s.gasLimitsWord()
	if err != nil {
		return common.Hash{}, err
	}
	if maxCost == nil || maxCost.Sign() < 0 {
		return common.Hash{}, fmt.Errorf("maxCost must be non-negative")
	}
	if maxCost.BitLen() > 128 {
		return common.Hash{}, fmt.Errorf("maxCost exceeds uint128")
	}

	buf := make([]byte, 0, 13*32)
	appendWord := func(b []byte) { buf = append(buf, b...) }
	appendBig := func(v *big.Int) {
		var w [32]byte
		v.FillBytes(w[:])
		appendWord(w[:])
	}
	appendAddr := func(a common.Address) {
		var w [32]byte
		copy(w[12:], a[:])
		appendWord(w[:])
	}

	appendAddr(op.Sender)
	appendBig(op.Nonce)
	initCodeHash := crypto.Keccak256Hash(op.InitCode)
	appendWord(initCodeHash[:])
	callDataHash := crypto.Keccak256Hash(op.CallData)
	appendWord(callDataHash[:])
	appendWord(accountGasLimits[:])
	appendWord(gasLimits[:])
	appendBig(op.PreVerificationGas)
	appendWord(gasFees[:])
	appendBig(s.ChainID)
	appendAddr(s.Address)
	appendBig(new(big.Int).SetUint64(validUntil))
	appendBig(new(big.Int).SetUint64(validAfter))
	appendBig(maxCost)

	return crypto.Keccak256Hash(buf), nil
}

// Approve signs an approval and returns the paymasterAndData to put on the
// operation.
//
// Call this BEFORE taking the userOpHash: the hash covers paymasterAndData, so
// sponsoring afterwards invalidates the passkey signature.
func (s *Sponsor) Approve(op *userop.UserOperation, validUntil, validAfter uint64, maxCost *big.Int) ([]byte, error) {
	if validUntil > maxUint48 || validAfter > maxUint48 {
		return nil, fmt.Errorf("validity timestamps must fit in uint48")
	}
	if validUntil != 0 && validAfter != 0 && validUntil <= validAfter {
		return nil, fmt.Errorf("validUntil %d is not after validAfter %d", validUntil, validAfter)
	}

	// The digest must be computed against the final gas-limit bytes, so fill
	// the field in first. The signature slot is zeroed; the digest excludes it.
	stub, err := s.encode(validUntil, validAfter, maxCost, make([]byte, 65))
	if err != nil {
		return nil, err
	}
	saved := op.PaymasterAndData
	op.PaymasterAndData = stub
	digest, err := s.ApprovalHash(op, validUntil, validAfter, maxCost)
	op.PaymasterAndData = saved
	if err != nil {
		return nil, err
	}

	sig, err := crypto.Sign(ethSignedMessageHash(digest), s.key)
	if err != nil {
		return nil, fmt.Errorf("sign approval: %w", err)
	}
	// crypto.Sign returns V as 0 or 1; Solidity's ecrecover and OpenZeppelin's
	// ECDSA both want 27 or 28. Signatures are already canonical low-s, which
	// OpenZeppelin v5 requires — the same malleability rule the P-256 side
	// enforces by hand.
	sig[64] += 27

	return s.encode(validUntil, validAfter, maxCost, sig)
}

const maxUint48 = 1<<48 - 1

// encode lays out paymasterAndData exactly as SokoniPaymaster parses it.
func (s *Sponsor) encode(validUntil, validAfter uint64, maxCost *big.Int, sig []byte) ([]byte, error) {
	if len(sig) != 65 {
		return nil, fmt.Errorf("signature must be 65 bytes, got %d", len(sig))
	}
	gasLimits, err := s.gasLimitsWord()
	if err != nil {
		return nil, err
	}
	if maxCost == nil || maxCost.Sign() < 0 || maxCost.BitLen() > 128 {
		return nil, fmt.Errorf("maxCost must be a non-negative uint128")
	}

	out := make([]byte, DataLength)
	copy(out[0:20], s.Address[:])
	copy(out[20:validUntilOffset], gasLimits[:])
	putUint48(out[validUntilOffset:validAfterOffset], validUntil)
	putUint48(out[validAfterOffset:maxCostOffset], validAfter)
	maxCost.FillBytes(out[maxCostOffset:signatureOffset])
	copy(out[signatureOffset:], sig)
	return out, nil
}

func putUint48(dst []byte, v uint64) {
	for i := range 6 {
		dst[5-i] = byte(v >> (8 * i))
	}
}

// ethSignedMessageHash applies the EIP-191 personal-sign prefix, matching
// OpenZeppelin's MessageHashUtils.toEthSignedMessageHash.
func ethSignedMessageHash(h common.Hash) []byte {
	return crypto.Keccak256([]byte("\x19Ethereum Signed Message:\n32"), h[:])
}
