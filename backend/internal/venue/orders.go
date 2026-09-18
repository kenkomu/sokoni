package venue

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

func orderSelector(signature string) []byte {
	return crypto.Keccak256([]byte(signature))[:4]
}

func mustType(t string) abi.Type {
	typ, err := abi.NewType(t, "", nil)
	if err != nil {
		panic(err)
	}
	return typ
}

var marketOrderArgs = abi.Arguments{
	{Type: mustType("uint96")},
	{Type: mustType("uint256")},
	{Type: mustType("bool")},
	{Type: mustType("bool")},
}

// maxUint96 bounds _size/_quoteAmount -- both are genuinely uint96 on
// OrderBook.sol, not uint256; go-ethereum's abi.Pack does not itself reject
// an oversized value for a narrower Solidity type, so this is checked here
// rather than trusting the packer to catch a caller's mistake.
var maxUint96 = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 96), big.NewInt(1))

func checkUint96(name string, v *big.Int) error {
	if v.Sign() < 0 {
		return fmt.Errorf("%s must be non-negative", name)
	}
	if v.Cmp(maxUint96) > 0 {
		return fmt.Errorf("%s %s does not fit uint96", name, v)
	}
	return nil
}

// EncodePlaceAndExecuteMarketBuy builds callData for Kuru's OrderBook.sol
// placeAndExecuteMarketBuy(uint96 _quoteAmount, uint256 _minAmountOut, bool
// _isMargin, bool _isFillOrKill). _quoteAmount is in the market's
// pricePrecision units -- see QuoteAmountRaw -- never raw quote-asset wei;
// that distinction (buy scales by pricePrecision, sell scales by
// sizePrecision, despite both looking like "an amount") is confirmed against
// Kuru's own source, not inferred, after it already cost this codebase a
// real scaling bug once (see internal/store/postgres.go's kuruVaultPricePrecision
// doc for the sibling case on Trade's price field).
func EncodePlaceAndExecuteMarketBuy(quoteAmountRaw, minAmountOut *big.Int, isMargin, isFillOrKill bool) ([]byte, error) {
	if err := checkUint96("quoteAmount", quoteAmountRaw); err != nil {
		return nil, err
	}
	if minAmountOut == nil || minAmountOut.Sign() < 0 {
		return nil, fmt.Errorf("minAmountOut must be non-negative")
	}
	args, err := marketOrderArgs.Pack(quoteAmountRaw, minAmountOut, isMargin, isFillOrKill)
	if err != nil {
		return nil, err
	}
	return append(orderSelector("placeAndExecuteMarketBuy(uint96,uint256,bool,bool)"), args...), nil
}

// EncodePlaceAndExecuteMarketSell builds callData for OrderBook.sol
// placeAndExecuteMarketSell(uint96 _size, uint256 _minAmountOut, bool
// _isMargin, bool _isFillOrKill). _size is in the market's sizePrecision
// units -- see SizeRaw.
func EncodePlaceAndExecuteMarketSell(sizeRaw, minAmountOut *big.Int, isMargin, isFillOrKill bool) ([]byte, error) {
	if err := checkUint96("size", sizeRaw); err != nil {
		return nil, err
	}
	if minAmountOut == nil || minAmountOut.Sign() < 0 {
		return nil, fmt.Errorf("minAmountOut must be non-negative")
	}
	args, err := marketOrderArgs.Pack(sizeRaw, minAmountOut, isMargin, isFillOrKill)
	if err != nil {
		return nil, err
	}
	return append(orderSelector("placeAndExecuteMarketSell(uint96,uint256,bool,bool)"), args...), nil
}

var approveArgs = abi.Arguments{
	{Type: mustType("address")},
	{Type: mustType("uint256")},
}

// EncodeApprove builds callData for the standard ERC-20
// approve(address,uint256) -- needed before selling an ERC-20 base asset
// (Kuru pulls it via transferFrom) or spending an ERC-20 quote asset on a
// buy; never needed for native MON, which attaches as msg.value instead.
func EncodeApprove(spender common.Address, amount *big.Int) ([]byte, error) {
	if amount == nil || amount.Sign() < 0 {
		return nil, fmt.Errorf("amount must be non-negative")
	}
	args, err := approveArgs.Pack(spender, amount)
	if err != nil {
		return nil, err
	}
	return append(orderSelector("approve(address,uint256)"), args...), nil
}

// SizeRaw converts a human amount of the base asset, in that asset's own
// smallest unit (wei for an 18-decimal token), to the sizePrecision-scaled
// `_size` placeAndExecuteMarketSell expects, following
// OrderBook.sol's own _sizePrecisionToBaseAssetPrecision in reverse:
// wei = size * 10^baseDecimals / sizePrecision, so size = wei * sizePrecision
// / 10^baseDecimals. baseDecimals itself never appears in that final
// division because it appears on both sides and cancels -- it is kept as a
// parameter anyway so a caller never has to re-derive that cancellation
// itself and get it wrong.
//
// actualWei is what the contract will actually treat this size as worth
// (recomputed the same floor-rounded way OrderBook.sol computes it), which
// can differ from baseWei by the floor-rounding both conversions apply. A
// caller must attach/approve actualWei, not baseWei -- the contract's own
// NativeAssetInsufficient/NativeAssetSurplus checks require msg.value to
// land in the exact one-unit band around the raw size's own conversion, not
// merely "close enough" to the human input.
func SizeRaw(baseWei *big.Int, sizePrecision int64, baseDecimals int32) (raw, actualWei *big.Int) {
	baseMul := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(baseDecimals)), nil)
	sp := big.NewInt(sizePrecision)
	raw = new(big.Int).Div(new(big.Int).Mul(baseWei, sp), baseMul)
	actualWei = new(big.Int).Div(new(big.Int).Mul(raw, baseMul), sp)
	return raw, actualWei
}

// QuoteAmountRaw is SizeRaw's twin for placeAndExecuteMarketBuy's
// _quoteAmount, which OrderBook.sol scales by pricePrecision instead of
// sizePrecision (_pricePrecisionToQuoteAssetPrecision): wei = quote *
// 10^quoteDecimals / pricePrecision, so quote = wei * pricePrecision /
// 10^quoteDecimals.
func QuoteAmountRaw(quoteWei *big.Int, pricePrecision int64, quoteDecimals int32) (raw, actualWei *big.Int) {
	quoteMul := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(quoteDecimals)), nil)
	pp := big.NewInt(pricePrecision)
	raw = new(big.Int).Div(new(big.Int).Mul(quoteWei, pp), quoteMul)
	actualWei = new(big.Int).Div(new(big.Int).Mul(raw, quoteMul), pp)
	return raw, actualWei
}
