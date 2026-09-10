package paymaster

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/kenkomu/sokoni/backend/internal/userop"
)

func maxCostSponsor(t *testing.T) *Sponsor {
	t.Helper()
	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	s, err := NewSponsorWithKey(common.HexToAddress("0xBEEF"), big.NewInt(10143), key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// The same figure as EXACT_PREFUND in SokoniPaymaster.t.sol, where the real
// EntryPoint accepts an approval for exactly this and refuses one wei less.
func TestMaxCostIsTheEntryPointPrefund(t *testing.T) {
	s := maxCostSponsor(t) // defaults: 120k paymaster verification, 0 postOp
	op := &userop.UserOperation{
		VerificationGasLimit: big.NewInt(600_000),
		CallGasLimit:         big.NewInt(400_000),
		PreVerificationGas:   big.NewInt(100_000),
		MaxFeePerGas:         big.NewInt(100e9),
	}
	want := new(big.Int).Mul(big.NewInt(600_000+400_000+100_000+120_000+0), big.NewInt(100e9))
	if got := s.MaxCost(op); got.Cmp(want) != 0 {
		t.Fatalf("MaxCost = %s, want %s", got, want)
	}
}

// Leaving out the paymaster's own gas is the easy mistake — it is not on the
// operation, it is inside paymasterAndData — and it would make every approval
// fall short of the prefund by exactly that much.
func TestMaxCostCountsThePaymastersOwnGas(t *testing.T) {
	s := maxCostSponsor(t)
	op := &userop.UserOperation{
		VerificationGasLimit: big.NewInt(1),
		CallGasLimit:         big.NewInt(1),
		PreVerificationGas:   big.NewInt(1),
		MaxFeePerGas:         big.NewInt(1),
	}
	base := s.MaxCost(op)
	s.PostOpGasLimit = big.NewInt(50_000)
	if got := s.MaxCost(op); new(big.Int).Sub(got, base).Int64() != 50_000 {
		t.Fatalf("raising postOp gas by 50k moved MaxCost by %s", new(big.Int).Sub(got, base))
	}
}

func TestMaxCostWithNoFeeIsZero(t *testing.T) {
	if got := maxCostSponsor(t).MaxCost(&userop.UserOperation{}); got.Sign() != 0 {
		t.Fatalf("got %s, want 0", got)
	}
}
