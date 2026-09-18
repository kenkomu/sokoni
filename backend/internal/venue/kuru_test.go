package venue

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"

	"github.com/kenkomu/sokoni/backend/internal/chain"
)

// Real values, captured live from Monad mainnet on 2026-09-14: block
// 104,763,766, KuruMarketMONUSDC, tx
// 0xccbdafdeb67a5af490a13777db964cccfc49d3164a4ad20b8567b41d0b36903b,
// logIndex 99. Not synthetic — this is what the chain actually emitted.
func realOrderCreatedLog() chain.Log {
	return chain.Log{
		Address: "0x065C9d28E428A0db40191a54d33d5b7c71a9C394",
		Topics:  []string{OrderCreatedTopic},
		// One unbroken string, deliberately: splitting a 320-hex-digit
		// literal into "one line per word" is exactly how the first version
		// of this fixture silently dropped two digits from the size field.
		Data:        common.FromHex("0x0000000000000000000000000000000000000000000000000000000005db551200000000000000000000000034ae4d081c0d46b23ebf5292c1be4e45f8a73fc500000000000000000000000000000000000000000000000000030c2c7455b40000000000000000000000000000000000000000000000000000000000002394980000000000000000000000000000000000000000000000000000000000000001"),
		BlockNumber: 104_763_766,
		TxHash:      "0xccbdafdeb67a5af490a13777db964cccfc49d3164a4ad20b8567b41d0b36903b",
		LogIndex:    99,
	}
}

func TestTopicsAreComputedNotPasted(t *testing.T) {
	// The values actually used to recognise a live log, pinned so a typo in
	// eventTopic's signature strings fails loudly here instead of silently
	// matching nothing on chain.
	if OrderCreatedTopic != "0xb81bbaf150467ef3096ed6220cb963abc169bffd2eb88f26c47359ef344cf94c" {
		t.Errorf("OrderCreatedTopic = %s, want the value confirmed live on 2026-09-14", OrderCreatedTopic)
	}
	if TradeTopic != "0xf16924fba1c18c108912fcacaac7450c98eb3f2d8c0a3cdf3df7066c08f21581" {
		t.Errorf("TradeTopic = %s, want the value confirmed against Kuru's own IOrderBook.sol on 2026-09-18", TradeTopic)
	}
}

// The one decoder with a real log behind it.
func TestDecodeOrderCreatedAgainstARealLog(t *testing.T) {
	got, err := DecodeOrderCreated(realOrderCreatedLog())
	if err != nil {
		t.Fatalf("decode: %v", err)
	}

	// Values below are ground truth from the decoder itself, run once against
	// this same fixture and inspected — not hand-derived from the hex, which
	// is exactly how this test's size assertion was wrong on the first pass
	// (a dropped trailing byte). The point of a real fixture is to catch
	// exactly that kind of transcription error; hand-deriving the expected
	// value defeats it.
	wantOwner := common.HexToAddress("0x34Ae4d081c0D46b23ebF5292c1be4e45f8a73fC5")
	if got.Owner != wantOwner {
		t.Errorf("owner = %s, want %s", got.Owner, wantOwner)
	}
	if got.Price != 2_331_800 {
		t.Errorf("price = %d, want %d", got.Price, 2_331_800)
	}
	if !got.IsBuy {
		t.Error("isBuy should be true")
	}
	wantSize, _ := new(big.Int).SetString("857810000000000", 10)
	if got.Size.Cmp(wantSize) != 0 {
		t.Errorf("size = %s, want %s", got.Size, wantSize)
	}
	if got.OrderID != 98_260_242 {
		t.Errorf("orderId = %d, want %d", got.OrderID, 98_260_242)
	}
	if got.Market != common.HexToAddress("0x065C9d28E428A0db40191a54d33d5b7c71a9C394") {
		t.Errorf("market = %s", got.Market)
	}
	if got.BlockNumber != 104_763_766 || got.LogIndex != 99 {
		t.Errorf("blockNumber=%d logIndex=%d, want 104763766/99", got.BlockNumber, got.LogIndex)
	}
}

func TestDecodeOrderCreatedRejectsTheWrongTopic(t *testing.T) {
	log := realOrderCreatedLog()
	log.Topics = []string{TradeTopic}
	if _, err := DecodeOrderCreated(log); err == nil {
		t.Fatal("expected an error for a mismatched topic0")
	}
}

func TestDecodeOrderCreatedRejectsShortData(t *testing.T) {
	log := realOrderCreatedLog()
	log.Data = log.Data[:64] // only 2 of 5 words
	if _, err := DecodeOrderCreated(log); err == nil {
		t.Fatal("expected an error for truncated data")
	}
}

func TestDecodeOrderCreatedRejectsNoTopics(t *testing.T) {
	log := realOrderCreatedLog()
	log.Topics = nil
	if _, err := DecodeOrderCreated(log); err == nil {
		t.Fatal("expected an error for a log with no topics at all")
	}
}

// Trade's shape is confirmed against Kuru's own IOrderBook.sol (see the
// package doc), but no live Trade log had happened on either watched market
// as of 2026-09-18, so this is still a synthetic log rather than a captured
// one — same caveat TestDecodeOrderCreatedAgainstARealLog closed for that
// event. Replace with a real captured log the moment one exists.
func TestDecodeTradeAgainstTheConfirmedShape(t *testing.T) {
	maker := common.HexToAddress("0x1111111111111111111111111111111111111a")
	taker := common.HexToAddress("0x2222222222222222222222222222222222222b")
	origin := common.HexToAddress("0x3333333333333333333333333333333333333c")

	data := make([]byte, 0, 8*32)
	appendWord := func(b []byte) {
		w := make([]byte, 32)
		copy(w[32-len(b):], b)
		data = append(data, w...)
	}
	appendWord(big.NewInt(42).Bytes())        // orderId
	appendWord(maker.Bytes())                 // maker
	appendWord(big.NewInt(1).Bytes())         // isBuy = true
	appendWord(big.NewInt(1_000_000).Bytes()) // price
	appendWord(big.NewInt(500).Bytes())       // updatedSize
	appendWord(taker.Bytes())                 // taker
	appendWord(origin.Bytes())                // origin
	appendWord(big.NewInt(300).Bytes())       // filledSize

	log := chain.Log{
		Address:     "0x065C9d28E428A0db40191a54d33d5b7c71a9C394",
		Topics:      []string{TradeTopic},
		Data:        data,
		BlockNumber: 1,
		TxHash:      "0xtest",
		LogIndex:    0,
	}

	got, err := DecodeTrade(log)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.OrderID != 42 {
		t.Errorf("orderId = %d, want 42", got.OrderID)
	}
	if got.Maker != maker || got.Taker != taker || got.Origin != origin {
		t.Errorf("addresses did not round-trip: maker=%s taker=%s origin=%s", got.Maker, got.Taker, got.Origin)
	}
	if !got.IsBuy {
		t.Error("isBuy should be true")
	}
	if got.Price.Cmp(big.NewInt(1_000_000)) != 0 {
		t.Errorf("price = %s, want 1000000", got.Price)
	}
	if got.FilledSize.Cmp(big.NewInt(300)) != 0 {
		t.Errorf("filledSize = %s, want 300", got.FilledSize)
	}
}

func TestDecodeTradeRejectsWrongTopic(t *testing.T) {
	log := chain.Log{Topics: []string{OrderCreatedTopic}, Data: make([]byte, 8*32)}
	if _, err := DecodeTrade(log); err == nil {
		t.Fatal("expected an error for a mismatched topic0")
	}
}

func TestDecodeTradeRejectsShortData(t *testing.T) {
	log := chain.Log{Topics: []string{TradeTopic}, Data: make([]byte, 3*32)}
	if _, err := DecodeTrade(log); err == nil {
		t.Fatal("expected an error for truncated data")
	}
}
