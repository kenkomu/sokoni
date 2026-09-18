package venue

import (
	"bytes"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

// Every "want" below is pinned against `cast calldata` directly against the
// real function signatures, the same authority already trusted elsewhere in
// this package for TradeTopic.

func TestEncodePlaceAndExecuteMarketBuyMatchesCast(t *testing.T) {
	got, err := EncodePlaceAndExecuteMarketBuy(big.NewInt(1_000_000_000), big.NewInt(0), false, false)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	want := hexutil.MustDecode("0x7c51d6cf000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
	if !bytes.Equal(got, want) {
		t.Fatalf("mismatch\n got %x\nwant %x", got, want)
	}
}

func TestEncodePlaceAndExecuteMarketSellMatchesCast(t *testing.T) {
	got, err := EncodePlaceAndExecuteMarketSell(big.NewInt(2_000_000_000_000), big.NewInt(0), false, true)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	want := hexutil.MustDecode("0x532c46db000000000000000000000000000000000000000000000000000001d1a94a2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001")
	if !bytes.Equal(got, want) {
		t.Fatalf("mismatch\n got %x\nwant %x", got, want)
	}
}

func TestEncodeApproveMatchesCast(t *testing.T) {
	spender := common.HexToAddress("0x065C9d28E428A0db40191a54d33d5b7c71a9C394")
	maxUint256 := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))

	got, err := EncodeApprove(spender, maxUint256)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	want := hexutil.MustDecode("0x095ea7b3000000000000000000000000065c9d28e428a0db40191a54d33d5b7c71a9c394ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
	if !bytes.Equal(got, want) {
		t.Fatalf("mismatch\n got %x\nwant %x", got, want)
	}
}

func TestEncodeMarketOrderRejectsOversizedUint96(t *testing.T) {
	tooBig := new(big.Int).Lsh(big.NewInt(1), 96) // exactly 2^96, one past the max
	if _, err := EncodePlaceAndExecuteMarketBuy(tooBig, big.NewInt(0), false, false); err == nil {
		t.Fatal("expected an error for a quoteAmount that does not fit uint96")
	}
	if _, err := EncodePlaceAndExecuteMarketSell(tooBig, big.NewInt(0), false, false); err == nil {
		t.Fatal("expected an error for a size that does not fit uint96")
	}
}

// SizeRaw/QuoteAmountRaw are checked against the real MON-USDC market
// (sizePrecision=1e10, baseDecimals=18) and the real seed trade this
// codebase actually placed on it (see migrations/0006's commit message):
// selling 200 MON needed _size=2e12 and exactly 200*1e18 wei attached.
func TestSizeRawMatchesTheRealSeedTrade(t *testing.T) {
	baseWei := new(big.Int).Mul(big.NewInt(200), pow10(18)) // 200 MON
	raw, actualWei := SizeRaw(baseWei, 10_000_000_000, 18)

	if raw.Cmp(big.NewInt(2_000_000_000_000)) != 0 {
		t.Errorf("raw = %s, want 2000000000000 (2e12)", raw)
	}
	if actualWei.Cmp(baseWei) != 0 {
		t.Errorf("actualWei = %s, want %s (200 MON, no rounding loss on a round number)", actualWei, baseWei)
	}
}

func TestSizeRawRoundsDownRatherThanOverspend(t *testing.T) {
	// 1 wei of MON is far below sizePrecision's own granularity (1e10 units
	// across 1e18 wei = one unit per 1e8 wei) -- raw must floor to 0, and
	// actualWei must floor to 0 with it, never round up to something the
	// caller never asked to spend.
	raw, actualWei := SizeRaw(big.NewInt(1), 10_000_000_000, 18)
	if raw.Sign() != 0 || actualWei.Sign() != 0 {
		t.Errorf("raw=%s actualWei=%s, want both 0 for 1 wei (below sizePrecision's granularity)", raw, actualWei)
	}
}

func TestQuoteAmountRawMatchesHandComputation(t *testing.T) {
	// 10 USDC (6 decimals) on a market with pricePrecision=1e8: raw = 10e6 *
	// 1e8 / 1e6 = 1e9, and it round-trips exactly since 10e6 is itself an
	// exact multiple of pricePrecision/quoteDecimalMultiplier's ratio.
	quoteWei := big.NewInt(10_000_000) // 10 USDC
	raw, actualWei := QuoteAmountRaw(quoteWei, 100_000_000, 6)

	if raw.Cmp(big.NewInt(1_000_000_000)) != 0 {
		t.Errorf("raw = %s, want 1000000000 (1e9)", raw)
	}
	if actualWei.Cmp(quoteWei) != 0 {
		t.Errorf("actualWei = %s, want %s", actualWei, quoteWei)
	}
}

func pow10(n int64) *big.Int {
	return new(big.Int).Exp(big.NewInt(10), big.NewInt(n), nil)
}
