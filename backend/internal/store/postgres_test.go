package store

import (
	"context"
	"math/big"
	"os"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/kenkomu/sokoni/backend/internal/chain"
	"github.com/kenkomu/sokoni/backend/internal/indexer"
	"github.com/kenkomu/sokoni/backend/internal/venue"
)

// Runs against a real Postgres. CI provides one; locally it skips unless
// DATABASE_URL is set (`make up && make migrate`).
func testStore(t *testing.T) *Store {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; CI runs this against a real Postgres")
	}
	s, err := Open(context.Background(), dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

// fakeVenue hands back a fixed set of logs regardless of the requested
// window, so a test can pin exactly which Trade the decoder sees.
type fakeVenue struct {
	logs []chain.Log
	err  error
}

func (f *fakeVenue) GetLogs(_ context.Context, _ string, _ []string, _, _ uint64) ([]chain.Log, error) {
	return f.logs, f.err
}

// A Trade log shaped the same way as internal/venue's synthetic fixture, on
// the MON-USDC market seeded by migrations/0002_fills_market_tape.sql.
func tradeLog(t *testing.T, price int64, filledSize int64, isBuy bool, txHash string, logIndex uint64) chain.Log {
	t.Helper()
	maker := common.HexToAddress("0x1111111111111111111111111111111111111a")
	taker := common.HexToAddress("0x2222222222222222222222222222222222222b")
	origin := common.HexToAddress("0x3333333333333333333333333333333333333c")

	data := make([]byte, 0, 8*32)
	appendWord := func(b []byte) {
		w := make([]byte, 32)
		copy(w[32-len(b):], b)
		data = append(data, w...)
	}
	appendWord(big.NewInt(1).Bytes()) // orderId
	appendWord(maker.Bytes())
	buy := int64(0)
	if isBuy {
		buy = 1
	}
	appendWord(big.NewInt(buy).Bytes())
	appendWord(big.NewInt(price).Bytes())
	appendWord(big.NewInt(filledSize).Bytes()) // updatedSize, unused by the decoder's caller
	appendWord(taker.Bytes())
	appendWord(origin.Bytes())
	appendWord(big.NewInt(filledSize).Bytes())

	return chain.Log{
		Address:     "0x065C9d28E428A0db40191a54d33d5b7c71a9C394", // KuruMarketMONUSDC
		Topics:      []string{venue.TradeTopic},
		Data:        data,
		BlockNumber: 1,
		TxHash:      txHash,
		LogIndex:    logIndex,
	}
}

func TestApplyBlocksDecodesAndInsertsAFill(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	consumer := "test-consumer-" + t.Name()

	txHash := "0x" + randHex(t)
	s.WithVenueClient(&fakeVenue{logs: []chain.Log{
		tradeLog(t, 2_331_800, 857_810_000_000_000, true, txHash, 0),
	}})

	headers := []chain.BlockHeader{{Number: 100, Hash: "0x" + randHex(t)}}
	cp := indexer.Checkpoint{BlockNumber: 100, BlockHash: headers[0].Hash}
	if err := s.ApplyBlocks(ctx, consumer, headers, cp); err != nil {
		t.Fatalf("ApplyBlocks: %v", err)
	}

	var market, side, px, qty string
	var accountID *int64
	var blockNumber int64
	err := s.pool.QueryRow(ctx,
		`select market, side, px::text, qty::text, account_id, block_number
		 from fills where tx_hash = $1 and log_index = 0`,
		mustDecodeHash(t, txHash)).Scan(&market, &side, &px, &qty, &accountID, &blockNumber)
	if err != nil {
		t.Fatalf("query fill: %v", err)
	}

	if market != "MON-USDC" {
		t.Errorf("market = %q, want MON-USDC", market)
	}
	if side != "buy" {
		t.Errorf("side = %q, want buy", side)
	}
	// price = 2_331_800 / pricePrecision(1e8) = 0.023318
	if px != "0.023318000000000000" {
		t.Errorf("px = %q, want 0.023318000000000000", px)
	}
	// filledSize = 857_810_000_000_000 / 10^baseDec(18) = 0.00085781
	if qty != "0.000857810000000000" {
		t.Errorf("qty = %q, want 0.000857810000000000", qty)
	}
	if accountID != nil {
		t.Errorf("accountID = %v, want nil: neither maker nor taker is a known account", *accountID)
	}
	if blockNumber != 1 {
		t.Errorf("blockNumber = %d, want 1", blockNumber)
	}

	// The checkpoint moved too, in the same transaction.
	loaded, found, err := s.LoadCheckpoint(ctx, consumer)
	if err != nil || !found {
		t.Fatalf("load checkpoint: found=%v err=%v", found, err)
	}
	if loaded.BlockNumber != 100 {
		t.Errorf("checkpoint block = %d, want 100", loaded.BlockNumber)
	}
}

func TestApplyBlocksMatchesAKnownAccount(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	consumer := "test-consumer-" + t.Name()

	taker := common.HexToAddress("0x2222222222222222222222222222222222222b")
	accountID := time.Now().UnixNano() // unique per run, avoids clashing with other tests' fixtures
	if _, err := s.pool.Exec(ctx,
		`insert into accounts (account_id, smart_account) values ($1, $2) on conflict do nothing`,
		accountID, taker.Bytes()); err != nil {
		t.Fatalf("seed account: %v", err)
	}
	// tradeLog's taker address is shared by every test in this file (it's a
	// fixture constant, not unique per call), so this row must not outlive
	// the test: left behind, it turns "no match" in every other test using
	// the same fixture into a false match on a stale account.
	t.Cleanup(func() {
		s.pool.Exec(context.Background(), `delete from accounts where account_id = $1`, accountID)
	})

	txHash := "0x" + randHex(t)
	s.WithVenueClient(&fakeVenue{logs: []chain.Log{
		tradeLog(t, 100, 2000, false, txHash, 0),
	}})

	headers := []chain.BlockHeader{{Number: 200, Hash: "0x" + randHex(t)}}
	cp := indexer.Checkpoint{BlockNumber: 200, BlockHash: headers[0].Hash}
	if err := s.ApplyBlocks(ctx, consumer, headers, cp); err != nil {
		t.Fatalf("ApplyBlocks: %v", err)
	}

	var got *int64
	if err := s.pool.QueryRow(ctx,
		`select account_id from fills where tx_hash = $1 and log_index = 0`,
		mustDecodeHash(t, txHash)).Scan(&got); err != nil {
		t.Fatalf("query fill: %v", err)
	}
	if got == nil || *got != accountID {
		t.Errorf("account_id = %v, want %d (matched via taker)", got, accountID)
	}
}

func TestApplyBlocksIsIdempotentOnReplay(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	consumer := "test-consumer-" + t.Name()

	txHash := "0x" + randHex(t)
	fv := &fakeVenue{logs: []chain.Log{tradeLog(t, 50, 10, true, txHash, 0)}}
	s.WithVenueClient(fv)

	headers := []chain.BlockHeader{{Number: 300, Hash: "0x" + randHex(t)}}
	cp := indexer.Checkpoint{BlockNumber: 300, BlockHash: headers[0].Hash}

	if err := s.ApplyBlocks(ctx, consumer, headers, cp); err != nil {
		t.Fatalf("first apply: %v", err)
	}
	// Same window, same logs, as a genuine reprocess after a crash would be.
	if err := s.ApplyBlocks(ctx, consumer, headers, cp); err != nil {
		t.Fatalf("second apply: %v", err)
	}

	var count int
	if err := s.pool.QueryRow(ctx,
		`select count(*) from fills where tx_hash = $1 and log_index = 0`,
		mustDecodeHash(t, txHash)).Scan(&count); err != nil {
		t.Fatalf("count fills: %v", err)
	}
	if count != 1 {
		t.Errorf("fills for this tx/logIndex = %d, want exactly 1 (fills_chain_uniq must dedupe a replay)", count)
	}
}

func TestApplyBlocksWithNoVenueClientOnlyAdvancesTheCheckpoint(t *testing.T) {
	s := testStore(t) // s.venue is left unset -- the cmd/gateway configuration
	ctx := context.Background()
	consumer := "test-consumer-" + t.Name()

	headers := []chain.BlockHeader{{Number: 400, Hash: "0x" + randHex(t)}}
	cp := indexer.Checkpoint{BlockNumber: 400, BlockHash: headers[0].Hash}
	if err := s.ApplyBlocks(ctx, consumer, headers, cp); err != nil {
		t.Fatalf("ApplyBlocks: %v", err)
	}

	loaded, found, err := s.LoadCheckpoint(ctx, consumer)
	if err != nil || !found {
		t.Fatalf("load checkpoint: found=%v err=%v", found, err)
	}
	if loaded.BlockNumber != 400 {
		t.Errorf("checkpoint block = %d, want 400", loaded.BlockNumber)
	}
}

func mustDecodeHash(t *testing.T, h string) []byte {
	t.Helper()
	b, err := decodeHash(h)
	if err != nil {
		t.Fatalf("decodeHash(%q): %v", h, err)
	}
	return b
}

func randHex(t *testing.T) string {
	t.Helper()
	// Unique enough for a test's own tx_hash without pulling in crypto/rand:
	// this only needs to not collide with other rows, never to be secret.
	n := time.Now().UnixNano()
	b := big.NewInt(n).Bytes()
	full := make([]byte, 32)
	copy(full[32-len(b):], b)
	return common.Bytes2Hex(full)
}
