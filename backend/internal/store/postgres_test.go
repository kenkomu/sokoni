package store

import (
	"context"
	"fmt"
	"math/big"
	"os"
	"strings"
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
// window, so a test can pin exactly which Trade the decoder sees. It does
// filter by address, though -- real eth_getLogs does, and applyTrades now
// calls GetLogs once per enabled market (see postgres.go's own comment on
// why: one call over the window, not per block); a fake that ignored
// address would hand every market the same log and let whichever market
// happens to be processed first "win" the tx_hash/log_index dedup, which is
// exactly the flakiness a real eth_getLogs call would never produce.
type fakeVenue struct {
	logs []chain.Log
	err  error
}

func (f *fakeVenue) GetLogs(_ context.Context, address string, _ []string, _, _ uint64) ([]chain.Log, error) {
	if f.err != nil {
		return nil, f.err
	}
	var out []chain.Log
	for _, lg := range f.logs {
		if strings.EqualFold(lg.Address, address) {
			out = append(out, lg)
		}
	}
	return out, nil
}

// A Trade log shaped the same way as internal/venue's synthetic fixture, on
// the MON-USDC market seeded by migrations/0002_fills_market_tape.sql.
// blockNumber must match a header ApplyBlocks is given in the same call --
// applyTrades looks up each trade's block timestamp from that window's
// headers and errors on a trade referencing a block outside it.
func tradeLog(t *testing.T, blockNumber uint64, price int64, filledSize int64, isBuy bool, txHash string, logIndex uint64) chain.Log {
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
		BlockNumber: blockNumber,
		TxHash:      txHash,
		LogIndex:    logIndex,
	}
}

// testHeader is one block header, timestamped so upsertCandle has something
// real to bucket by.
func testHeader(number uint64) chain.BlockHeader {
	return chain.BlockHeader{
		Number:    number,
		Hash:      "0x" + fmt.Sprintf("%064x", number),
		Timestamp: uint64(time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC).Unix()) + number,
	}
}

// cleanupCandle deletes the one candle bucket a testHeader-backed trade
// would land in. Every fill-creating test uses a fixed block number (so a
// second call has something deterministic to look up), which means a
// candle's bucket_ts is the same on every run of the test process -- unlike
// fills, which key on a fresh random tx_hash, a candle row would otherwise
// accumulate trade_count across separate `go test` invocations instead of
// each run starting clean.
// Deletes every interval's bucket a trade at this header would touch, not
// just the 1-minute one -- applyTrade writes all of candleIntervalsS from a
// single trade, so leaving the coarser buckets behind lets one test's
// candle bleed into another's if their block timestamps (all derived from
// the same base time in testHeader) happen to fall in the same 5m/1h/1d
// window, which most of them do.
func cleanupCandle(t *testing.T, s *Store, market string, h chain.BlockHeader) {
	t.Helper()
	ts := time.Unix(int64(h.Timestamp), 0).UTC()
	for _, intervalS := range candleIntervalsS {
		bucket := ts.Truncate(time.Duration(intervalS) * time.Second)
		t.Cleanup(func(intervalS int, bucket time.Time) func() {
			return func() {
				s.pool.Exec(context.Background(),
					`delete from candles where market = $1 and interval_s = $2 and bucket_ts = $3`,
					market, intervalS, bucket)
			}
		}(intervalS, bucket))
	}
}

func TestApplyBlocksDecodesAndInsertsAFill(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	consumer := "test-consumer-" + t.Name()

	txHash := "0x" + randHex(t)
	s.WithVenueClient(&fakeVenue{logs: []chain.Log{
		tradeLog(t, 100, 23_318_000_000_000_000, 8_578_100, true, txHash, 0),
	}})

	headers := []chain.BlockHeader{testHeader(100)}
	cleanupCandle(t, s, "MON-USDC", headers[0])
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
	// price = 23_318_000_000_000_000 / kuruVaultPricePrecision(1e18) = 0.023318
	if px != "0.023318000000000000" {
		t.Errorf("px = %q, want 0.023318000000000000", px)
	}
	// filledSize = 8_578_100 / sizePrecision(1e10) = 0.00085781
	if qty != "0.000857810000000000" {
		t.Errorf("qty = %q, want 0.000857810000000000", qty)
	}
	if accountID != nil {
		t.Errorf("accountID = %v, want nil: neither maker nor taker is a known account", *accountID)
	}
	if blockNumber != 100 {
		t.Errorf("blockNumber = %d, want 100", blockNumber)
	}

	bucket := time.Unix(int64(headers[0].Timestamp), 0).UTC().Truncate(candleIntervalS * time.Second)
	var openPx, highPx, lowPx, closePx, volume string
	var tradeCount int
	if err := s.pool.QueryRow(ctx,
		`select open_px::text, high_px::text, low_px::text, close_px::text, volume::text, trade_count
		 from candles where market = $1 and interval_s = $2 and bucket_ts = $3`,
		"MON-USDC", candleIntervalS, bucket).Scan(&openPx, &highPx, &lowPx, &closePx, &volume, &tradeCount); err != nil {
		t.Fatalf("query candle: %v", err)
	}
	for name, got := range map[string]string{"open_px": openPx, "high_px": highPx, "low_px": lowPx, "close_px": closePx} {
		if got != "0.023318000000000000" {
			t.Errorf("candle %s = %q, want 0.023318000000000000", name, got)
		}
	}
	if volume != "0.000857810000000000" {
		t.Errorf("candle volume = %q, want 0.000857810000000000", volume)
	}
	if tradeCount != 1 {
		t.Errorf("candle trade_count = %d, want 1", tradeCount)
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

// One trade must land in every interval in candleIntervalsS, not just the
// 1-minute one every other test in this file checks -- this is what the
// trade screen's 1H/6H/24H/1W/30D tabs actually read from (see mobile's
// TradeController.loadInitial, which now passes a real interval alongside
// limit).
func TestApplyBlocksPopulatesEveryCandleInterval(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	consumer := "test-consumer-" + t.Name()

	txHash := "0x" + randHex(t)
	s.WithVenueClient(&fakeVenue{logs: []chain.Log{
		tradeLog(t, 400, 23_318_000_000_000_000, 8_578_100, true, txHash, 0),
	}})

	headers := []chain.BlockHeader{testHeader(400)}
	cleanupCandle(t, s, "MON-USDC", headers[0])
	cp := indexer.Checkpoint{BlockNumber: 400, BlockHash: headers[0].Hash}
	if err := s.ApplyBlocks(ctx, consumer, headers, cp); err != nil {
		t.Fatalf("ApplyBlocks: %v", err)
	}

	for _, intervalS := range candleIntervalsS {
		bucketTs := time.Unix(int64(headers[0].Timestamp), 0).UTC().Truncate(time.Duration(intervalS) * time.Second)
		var tradeCount int
		err := s.pool.QueryRow(ctx,
			`select trade_count from candles where market = $1 and interval_s = $2 and bucket_ts = $3`,
			"MON-USDC", intervalS, bucketTs).Scan(&tradeCount)
		if err != nil {
			t.Errorf("interval %ds: query candle: %v", intervalS, err)
			continue
		}
		if tradeCount != 1 {
			t.Errorf("interval %ds: trade_count = %d, want 1", intervalS, tradeCount)
		}
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

	// price = 1_000_000_000_000_000_000 / kuruVaultPricePrecision(1e18) = 1.0 USDC per MON.
	// filledSize = 50_000_000 / sizePrecision(1e10) = 0.005 MON.
	// isBuy=false and the taker matched, so our own side is a sell: MON out,
	// USDC in.
	txHash := "0x" + randHex(t)
	s.WithVenueClient(&fakeVenue{logs: []chain.Log{
		tradeLog(t, 200, 1_000_000_000_000_000_000, 50_000_000, false, txHash, 0),
	}})

	headers := []chain.BlockHeader{testHeader(200)}
	cleanupCandle(t, s, "MON-USDC", headers[0])
	cp := indexer.Checkpoint{BlockNumber: 200, BlockHash: headers[0].Hash}
	if err := s.ApplyBlocks(ctx, consumer, headers, cp); err != nil {
		t.Fatalf("ApplyBlocks: %v", err)
	}

	var got *int64
	var fillID int64
	if err := s.pool.QueryRow(ctx,
		`select account_id, fill_id from fills where tx_hash = $1 and log_index = 0`,
		mustDecodeHash(t, txHash)).Scan(&got, &fillID); err != nil {
		t.Fatalf("query fill: %v", err)
	}
	if got == nil || *got != accountID {
		t.Errorf("account_id = %v, want %d (matched via taker)", got, accountID)
	}

	legs := map[string]string{}
	rows, err := s.pool.Query(ctx,
		`select asset, delta::text from ledger_entries where txn_id = $1 and account_id = $2`,
		fillID, accountID)
	if err != nil {
		t.Fatalf("query ledger_entries: %v", err)
	}
	for rows.Next() {
		var asset, delta string
		if err := rows.Scan(&asset, &delta); err != nil {
			t.Fatalf("scan ledger_entries: %v", err)
		}
		legs[asset] = delta
	}
	rows.Close()

	if len(legs) != 2 {
		t.Fatalf("ledger_entries legs = %v, want exactly 2 (base and quote)", legs)
	}
	if legs["MON"] != "-0.005000000000000000" {
		t.Errorf("MON leg = %q, want -0.005000000000000000 (we sold MON)", legs["MON"])
	}
	if legs["USDC"] != "0.005000000000000000" {
		t.Errorf("USDC leg = %q, want 0.005000000000000000 (we received USDC)", legs["USDC"])
	}
}

func TestApplyBlocksIsIdempotentOnReplay(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()
	consumer := "test-consumer-" + t.Name()

	txHash := "0x" + randHex(t)
	fv := &fakeVenue{logs: []chain.Log{tradeLog(t, 300, 50, 10, true, txHash, 0)}}
	s.WithVenueClient(fv)

	headers := []chain.BlockHeader{testHeader(300)}
	cleanupCandle(t, s, "MON-USDC", headers[0])
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

	// A replayed fill must not double-count its candle: applyTrade returns
	// before touching the candle once the fill insert reports a duplicate.
	bucket := time.Unix(int64(headers[0].Timestamp), 0).UTC().Truncate(candleIntervalS * time.Second)
	var tradeCount int
	if err := s.pool.QueryRow(ctx,
		`select trade_count from candles where market = $1 and interval_s = $2 and bucket_ts = $3`,
		"MON-USDC", candleIntervalS, bucket).Scan(&tradeCount); err != nil {
		t.Fatalf("query candle: %v", err)
	}
	if tradeCount != 1 {
		t.Errorf("candle trade_count = %d, want exactly 1 (a replay must not double-count)", tradeCount)
	}
}

func TestApplyBlocksWithNoVenueClientOnlyAdvancesTheCheckpoint(t *testing.T) {
	s := testStore(t) // s.venue is left unset -- the cmd/gateway configuration
	ctx := context.Background()
	consumer := "test-consumer-" + t.Name()

	headers := []chain.BlockHeader{testHeader(400)}
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
