// Package userop builds, packs and hashes ERC-4337 v0.7 user operations.
//
// This is the backend half of the client/server split: the phone never
// ABI-encodes anything. We build the operation, hand the client a userOpHash to
// sign with its passkey, and encode the assertion back into the signature
// field. So the phone needs no chain libraries, and the encoding lives in
// exactly one place where it can be tested against the contract.
//
// A v0.7 operation has two different shapes and confusing them is the classic
// way to waste an afternoon:
//
//   - The PACKED form, which the EntryPoint hashes and which the account sees.
//     `verificationGasLimit` and `callGasLimit` are squeezed into one word, as
//     are the two gas fees, and the paymaster fields are one opaque byte string.
//   - The UNPACKED form, which bundlers speak over JSON-RPC. Every field is
//     separate, `initCode` is split into `factory`/`factoryData`, and
//     `paymasterAndData` is split into four fields.
//
// Hash() uses the first. MarshalJSON() emits the second.
package userop

import (
	"encoding/json"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/crypto"
)

// UserOperation is an ERC-4337 v0.7 operation, held unpacked.
type UserOperation struct {
	Sender   common.Address
	Nonce    *big.Int
	InitCode []byte
	CallData []byte

	VerificationGasLimit *big.Int
	CallGasLimit         *big.Int
	PreVerificationGas   *big.Int
	MaxPriorityFeePerGas *big.Int
	MaxFeePerGas         *big.Int

	PaymasterAndData []byte
	Signature        []byte
}

// maxUint128 bounds the fields v0.7 packs two-to-a-word.
var maxUint128 = new(big.Int).Lsh(big.NewInt(1), 128)

func packUints(hi, lo *big.Int) ([32]byte, error) {
	var out [32]byte
	if hi == nil || lo == nil {
		return out, fmt.Errorf("packed gas field is nil")
	}
	if hi.Sign() < 0 || lo.Sign() < 0 {
		return out, fmt.Errorf("packed gas field is negative")
	}
	if hi.Cmp(maxUint128) >= 0 || lo.Cmp(maxUint128) >= 0 {
		return out, fmt.Errorf("packed gas field exceeds uint128")
	}
	packed := new(big.Int).Lsh(hi, 128)
	packed.Or(packed, lo)
	packed.FillBytes(out[:])
	return out, nil
}

// AccountGasLimits is verificationGasLimit in the high 128 bits, callGasLimit in
// the low. Note the order: verification first, which is the opposite of the
// order the JSON-RPC form lists them in.
func (op *UserOperation) AccountGasLimits() ([32]byte, error) {
	return packUints(op.VerificationGasLimit, op.CallGasLimit)
}

// GasFees is maxPriorityFeePerGas in the high 128 bits, maxFeePerGas in the low.
func (op *UserOperation) GasFees() ([32]byte, error) {
	return packUints(op.MaxPriorityFeePerGas, op.MaxFeePerGas)
}

func word(v *big.Int) ([32]byte, error) {
	var out [32]byte
	if v == nil {
		return out, fmt.Errorf("nil integer")
	}
	if v.Sign() < 0 {
		return out, fmt.Errorf("negative integer")
	}
	if v.BitLen() > 256 {
		return out, fmt.Errorf("integer exceeds 256 bits")
	}
	v.FillBytes(out[:])
	return out, nil
}

func addressWord(a common.Address) [32]byte {
	var out [32]byte
	copy(out[12:], a[:])
	return out
}

// encode is the EntryPoint's UserOperationLib.encode: every field is static or
// pre-hashed, so abi.encode is just the words end to end.
func (op *UserOperation) encode() ([]byte, error) {
	accountGasLimits, err := op.AccountGasLimits()
	if err != nil {
		return nil, fmt.Errorf("accountGasLimits: %w", err)
	}
	gasFees, err := op.GasFees()
	if err != nil {
		return nil, fmt.Errorf("gasFees: %w", err)
	}
	nonce, err := word(op.Nonce)
	if err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	preVerificationGas, err := word(op.PreVerificationGas)
	if err != nil {
		return nil, fmt.Errorf("preVerificationGas: %w", err)
	}

	out := make([]byte, 0, 8*32)
	for _, w := range [][32]byte{
		addressWord(op.Sender),
		nonce,
		crypto.Keccak256Hash(op.InitCode),
		crypto.Keccak256Hash(op.CallData),
		accountGasLimits,
		preVerificationGas,
		gasFees,
		crypto.Keccak256Hash(op.PaymasterAndData),
	} {
		out = append(out, w[:]...)
	}
	return out, nil
}

// Hash is the userOpHash the EntryPoint computes and the passkey signs.
//
// It binds the operation to one EntryPoint on one chain, so an operation signed
// for testnet cannot be replayed on mainnet.
func (op *UserOperation) Hash(entryPoint common.Address, chainID *big.Int) (common.Hash, error) {
	inner, err := op.encode()
	if err != nil {
		return common.Hash{}, err
	}
	chain, err := word(chainID)
	if err != nil {
		return common.Hash{}, fmt.Errorf("chainID: %w", err)
	}

	outer := make([]byte, 0, 3*32)
	innerHash := crypto.Keccak256Hash(inner)
	ep := addressWord(entryPoint)
	outer = append(outer, innerHash[:]...)
	outer = append(outer, ep[:]...)
	outer = append(outer, chain[:]...)

	return crypto.Keccak256Hash(outer), nil
}

// rpcUserOp is the shape bundlers accept. Optional groups are omitted entirely
// rather than sent as zero values — a bundler reading `"paymaster": "0x0"` will
// try to call it.
type rpcUserOp struct {
	Sender               string `json:"sender"`
	Nonce                string `json:"nonce"`
	Factory              string `json:"factory,omitempty"`
	FactoryData          string `json:"factoryData,omitempty"`
	CallData             string `json:"callData"`
	CallGasLimit         string `json:"callGasLimit"`
	VerificationGasLimit string `json:"verificationGasLimit"`
	PreVerificationGas   string `json:"preVerificationGas"`
	MaxFeePerGas         string `json:"maxFeePerGas"`
	MaxPriorityFeePerGas string `json:"maxPriorityFeePerGas"`

	Paymaster                     string `json:"paymaster,omitempty"`
	PaymasterVerificationGasLimit string `json:"paymasterVerificationGasLimit,omitempty"`
	PaymasterPostOpGasLimit       string `json:"paymasterPostOpGasLimit,omitempty"`
	PaymasterData                 string `json:"paymasterData,omitempty"`

	Signature string `json:"signature"`
}

// MarshalJSON emits the unpacked v0.7 wire form.
func (op *UserOperation) MarshalJSON() ([]byte, error) {
	r := rpcUserOp{
		Sender:               op.Sender.Hex(),
		Nonce:                hexutil.EncodeBig(op.Nonce),
		CallData:             hexutil.Encode(op.CallData),
		CallGasLimit:         hexutil.EncodeBig(op.CallGasLimit),
		VerificationGasLimit: hexutil.EncodeBig(op.VerificationGasLimit),
		PreVerificationGas:   hexutil.EncodeBig(op.PreVerificationGas),
		MaxFeePerGas:         hexutil.EncodeBig(op.MaxFeePerGas),
		MaxPriorityFeePerGas: hexutil.EncodeBig(op.MaxPriorityFeePerGas),
		Signature:            hexutil.Encode(op.Signature),
	}

	// initCode is factory address followed by its calldata.
	if len(op.InitCode) > 0 {
		if len(op.InitCode) < 20 {
			return nil, fmt.Errorf("initCode is %d bytes, too short to hold a factory address", len(op.InitCode))
		}
		r.Factory = common.BytesToAddress(op.InitCode[:20]).Hex()
		r.FactoryData = hexutil.Encode(op.InitCode[20:])
	}

	if len(op.PaymasterAndData) > 0 {
		if len(op.PaymasterAndData) < PaymasterDataOffset {
			return nil, fmt.Errorf(
				"paymasterAndData is %d bytes, need at least %d for address and gas limits",
				len(op.PaymasterAndData), PaymasterDataOffset)
		}
		r.Paymaster = common.BytesToAddress(op.PaymasterAndData[:20]).Hex()
		r.PaymasterVerificationGasLimit = hexutil.EncodeBig(
			new(big.Int).SetBytes(op.PaymasterAndData[PaymasterValidationGasOffset:PaymasterPostOpGasOffset]))
		r.PaymasterPostOpGasLimit = hexutil.EncodeBig(
			new(big.Int).SetBytes(op.PaymasterAndData[PaymasterPostOpGasOffset:PaymasterDataOffset]))
		r.PaymasterData = hexutil.Encode(op.PaymasterAndData[PaymasterDataOffset:])
	}

	return json.Marshal(r)
}

// Offsets into paymasterAndData, fixed by ERC-4337 v0.7 itself. Mirrors
// UserOperationLib's constants of the same names.
const (
	PaymasterValidationGasOffset = 20
	PaymasterPostOpGasOffset     = 36
	PaymasterDataOffset          = 52
)
