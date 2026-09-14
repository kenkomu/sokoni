// Package venue decodes events from the on-chain order book ADR 1 builds
// around: the matching core we never reimplement, only read from.
//
// Kuru is Monad's on-chain CLOB (docs.kuru.io). Addresses live in
// internal/chain/addresses.go, next to everything else this codebase treats
// as load-bearing enough to verify on-chain rather than paste from a page.
//
// A real caveat, found while building this: a keccak match on an event's
// topic0 proves its *type list* — the canonical signature string a hash is
// taken over says nothing about which parameters are `indexed`. Decoding a
// real, live-captured OrderCreated log (block 104,763,766, tx
// 0xccbdafdeb67a5af490a13777db964cccfc49d3164a4ad20b8567b41d0b36903b,
// logIndex 99) against docs.kuru.io's claimed layout — orderId and owner
// indexed — failed: the log carried exactly one topic (topic0) and all five
// fields in data, in declaration order. The docs summary was wrong about
// indexing even though the type list it gave was right.
//
// DecodeOrderCreated below matches what was actually observed on chain.
// DecodeTrade does not have that luxury — no live Trade event was found in
// the ranges searched on 2026-09-14 — so it is decoded on the same
// topic0-only shape OrderCreated turned out to have, as the best-supported
// assumption available, not as something independently confirmed. Treat it
// as provisional until a real Trade log is captured and checked the same
// way; TestDecodeTrade documents exactly this gap rather than hiding it
// behind a passing test built from the same assumption it exists to check.
package venue

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/kenkomu/sokoni/backend/internal/chain"
)

// Event topics. Computed from the canonical signature, not pasted — see
// internal/account.selector for the reasoning: a hand-copied hash is a
// silent misdial.
var (
	TradeTopic         = eventTopic("Trade(uint40,address,bool,uint32,uint96,address,address,uint96)")
	OrderCreatedTopic  = eventTopic("OrderCreated(uint40,address,uint96,uint32,bool)")
	OrderCanceledTopic = eventTopic("OrderCanceled(uint40,address,uint96,uint32,bool)")
)

func eventTopic(signature string) string {
	return "0x" + common.Bytes2Hex(crypto.Keccak256([]byte(signature)))
}

// Trade is one match on a Kuru order book.
//
// Field order and types follow docs.kuru.io/contracts/OrderBook; the
// indexed/non-indexed split is inferred, not confirmed — see the package
// doc.
type Trade struct {
	OrderID     uint64
	Maker       common.Address
	IsBuy       bool
	Price       uint32
	UpdatedSize *big.Int
	Taker       common.Address
	Origin      common.Address
	FilledSize  *big.Int

	Market      common.Address
	BlockNumber uint64
	TxHash      string
	LogIndex    uint64
}

// OrderCreated is a resting limit order entering the book. Confirmed against
// a real log — see the package doc.
type OrderCreated struct {
	OrderID uint64
	Owner   common.Address
	Size    *big.Int
	Price   uint32
	IsBuy   bool

	Market      common.Address
	BlockNumber uint64
	TxHash      string
	LogIndex    uint64
}

// word reads one 32-byte ABI slot from data at the given index, erroring
// rather than panicking on a short log — a log from an event we do not
// expect on this address is corrupt input, not a programming bug.
func word(data []byte, i int) ([]byte, error) {
	start := i * 32
	if start+32 > len(data) {
		return nil, fmt.Errorf("log data is %d bytes, too short for word %d", len(data), i)
	}
	return data[start : start+32], nil
}

func addressAt(data []byte, i int) (common.Address, error) {
	w, err := word(data, i)
	if err != nil {
		return common.Address{}, err
	}
	return common.BytesToAddress(w), nil
}

func uintAt(data []byte, i int) (*big.Int, error) {
	w, err := word(data, i)
	if err != nil {
		return nil, err
	}
	return new(big.Int).SetBytes(w), nil
}

func boolAt(data []byte, i int) (bool, error) {
	w, err := word(data, i)
	if err != nil {
		return false, err
	}
	return new(big.Int).SetBytes(w).Sign() != 0, nil
}

// DecodeTrade decodes one Trade log. See the package doc for what is and is
// not independently confirmed about this shape.
func DecodeTrade(log chain.Log) (*Trade, error) {
	if len(log.Topics) == 0 || log.Topics[0] != TradeTopic {
		return nil, fmt.Errorf("not a Trade log: topic0 %v", log.Topics)
	}
	orderID, err := uintAt(log.Data, 0)
	if err != nil {
		return nil, fmt.Errorf("orderId: %w", err)
	}
	maker, err := addressAt(log.Data, 1)
	if err != nil {
		return nil, fmt.Errorf("maker: %w", err)
	}
	isBuy, err := boolAt(log.Data, 2)
	if err != nil {
		return nil, fmt.Errorf("isBuy: %w", err)
	}
	price, err := uintAt(log.Data, 3)
	if err != nil {
		return nil, fmt.Errorf("price: %w", err)
	}
	updatedSize, err := uintAt(log.Data, 4)
	if err != nil {
		return nil, fmt.Errorf("updatedSize: %w", err)
	}
	taker, err := addressAt(log.Data, 5)
	if err != nil {
		return nil, fmt.Errorf("taker: %w", err)
	}
	origin, err := addressAt(log.Data, 6)
	if err != nil {
		return nil, fmt.Errorf("origin: %w", err)
	}
	filledSize, err := uintAt(log.Data, 7)
	if err != nil {
		return nil, fmt.Errorf("filledSize: %w", err)
	}
	if !price.IsUint64() || price.Uint64() > 0xFFFFFFFF {
		return nil, fmt.Errorf("price %s does not fit uint32", price)
	}

	return &Trade{
		OrderID:     orderID.Uint64(),
		Maker:       maker,
		IsBuy:       isBuy,
		Price:       uint32(price.Uint64()),
		UpdatedSize: updatedSize,
		Taker:       taker,
		Origin:      origin,
		FilledSize:  filledSize,
		Market:      common.HexToAddress(log.Address),
		BlockNumber: log.BlockNumber,
		TxHash:      log.TxHash,
		LogIndex:    log.LogIndex,
	}, nil
}

// DecodeOrderCreated decodes one OrderCreated log. This shape is confirmed —
// see the package doc.
func DecodeOrderCreated(log chain.Log) (*OrderCreated, error) {
	if len(log.Topics) == 0 || log.Topics[0] != OrderCreatedTopic {
		return nil, fmt.Errorf("not an OrderCreated log: topic0 %v", log.Topics)
	}
	orderID, err := uintAt(log.Data, 0)
	if err != nil {
		return nil, fmt.Errorf("orderId: %w", err)
	}
	owner, err := addressAt(log.Data, 1)
	if err != nil {
		return nil, fmt.Errorf("owner: %w", err)
	}
	size, err := uintAt(log.Data, 2)
	if err != nil {
		return nil, fmt.Errorf("size: %w", err)
	}
	price, err := uintAt(log.Data, 3)
	if err != nil {
		return nil, fmt.Errorf("price: %w", err)
	}
	isBuy, err := boolAt(log.Data, 4)
	if err != nil {
		return nil, fmt.Errorf("isBuy: %w", err)
	}
	if !price.IsUint64() || price.Uint64() > 0xFFFFFFFF {
		return nil, fmt.Errorf("price %s does not fit uint32", price)
	}

	return &OrderCreated{
		OrderID:     orderID.Uint64(),
		Owner:       owner,
		Size:        size,
		Price:       uint32(price.Uint64()),
		IsBuy:       isBuy,
		Market:      common.HexToAddress(log.Address),
		BlockNumber: log.BlockNumber,
		TxHash:      log.TxHash,
		LogIndex:    log.LogIndex,
	}, nil
}
