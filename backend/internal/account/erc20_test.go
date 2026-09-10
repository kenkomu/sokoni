package account

import (
	"bytes"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

// The selectors every ERC-20 in existence answers to. Derived, then checked
// against the values the whole ecosystem already agrees on.
func TestERC20SelectorsAreTheStandardOnes(t *testing.T) {
	if got := Hex(selector("transfer(address,uint256)")); got != "0xa9059cbb" {
		t.Errorf("transfer selector = %s, want 0xa9059cbb", got)
	}
	if got := Hex(selector("balanceOf(address)")); got != "0x70a08231" {
		t.Errorf("balanceOf selector = %s, want 0x70a08231", got)
	}
}

func TestEncodeERC20TransferLayout(t *testing.T) {
	to := common.HexToAddress("0x00000000000000000000000000000000000000C0")
	got, err := EncodeERC20Transfer(to, big.NewInt(1_000_000))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 4+32+32 {
		t.Fatalf("length %d, want 68", len(got))
	}
	if !bytes.Equal(got[4+12:4+32], to.Bytes()) {
		t.Errorf("recipient not in the first word: %x", got[4:36])
	}
	if new(big.Int).SetBytes(got[36:]).Int64() != 1_000_000 {
		t.Errorf("amount not in the second word: %x", got[36:])
	}
}

func TestEncodeERC20TransferRejectsNonPositive(t *testing.T) {
	to := common.HexToAddress("0xC0")
	for _, amt := range []*big.Int{nil, big.NewInt(0), big.NewInt(-1)} {
		if _, err := EncodeERC20Transfer(to, amt); err == nil {
			t.Errorf("amount %v must be rejected", amt)
		}
	}
}
