package store

import (
	"context"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

func TestListMarketsReturnsEnabledOnly(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()

	markets, err := s.ListMarkets(ctx)
	if err != nil {
		t.Fatalf("ListMarkets: %v", err)
	}

	bySymbol := map[string]Market{}
	for _, m := range markets {
		bySymbol[m.Symbol] = m
	}
	for _, want := range []string{"MON-USDC", "MON-AUSD"} {
		if _, ok := bySymbol[want]; !ok {
			t.Errorf("ListMarkets did not include %s, seeded by 0002_fills_market_tape.sql", want)
		}
	}

	m, ok := bySymbol["MON-USDC"]
	if !ok {
		t.Fatal("MON-USDC missing")
	}
	if m.TickSize != "0.000001000000000000" {
		t.Errorf("MON-USDC tick_size = %q, want 0.000001000000000000", m.TickSize)
	}
	// 200 MON, not 0.000002 -- see migrations/0006_kuru_size_precision.sql
	// for why the original value was wrong (missing the sizePrecision
	// conversion minSize actually needs).
	if m.MinQty != "200.000000000000000000" {
		t.Errorf("MON-USDC min_qty = %q, want 200.000000000000000000", m.MinQty)
	}
	if m.PricePrecision != 100000000 {
		t.Errorf("MON-USDC price_precision = %d, want 100000000", m.PricePrecision)
	}
	if len(m.BaseToken) != 20 || len(m.QuoteToken) != 20 {
		t.Errorf("token addresses should be 20 raw bytes: base=%d quote=%d", len(m.BaseToken), len(m.QuoteToken))
	}
}

func TestMarketBySymbolNotFound(t *testing.T) {
	s := testStore(t)
	_, found, err := s.MarketBySymbol(context.Background(), "NOT-A-REAL-MARKET")
	if err != nil {
		t.Fatalf("MarketBySymbol: %v", err)
	}
	if found {
		t.Error("found = true, want false for an unknown symbol")
	}
}

func TestMarketBySymbolFindsASeededMarket(t *testing.T) {
	s := testStore(t)
	m, found, err := s.MarketBySymbol(context.Background(), "MON-AUSD")
	if err != nil {
		t.Fatalf("MarketBySymbol: %v", err)
	}
	if !found {
		t.Fatal("MON-AUSD not found, expected it seeded by 0002_fills_market_tape.sql")
	}
	if m.Venue != "kuru" {
		t.Errorf("venue = %q, want kuru", m.Venue)
	}
}

func TestCandlesReturnsAscendingByBucket(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()

	base := time.Date(2026, 9, 15, 8, 0, 0, 0, time.UTC)
	buckets := []time.Time{base, base.Add(60 * time.Second), base.Add(120 * time.Second)}
	closes := []string{"1.000000000000000000", "1.100000000000000000", "1.200000000000000000"}

	t.Cleanup(func() {
		for _, b := range buckets {
			s.pool.Exec(context.Background(),
				`delete from candles where market = $1 and interval_s = $2 and bucket_ts = $3`,
				"MON-USDC", candleIntervalS, b)
		}
	})
	for i, b := range buckets {
		if _, err := s.pool.Exec(ctx, `
			insert into candles (market, interval_s, bucket_ts, open_px, high_px, low_px, close_px, volume, trade_count)
			values ($1, $2, $3, $4, $4, $4, $4, '1', 1)`,
			"MON-USDC", candleIntervalS, b, closes[i]); err != nil {
			t.Fatalf("seed candle %d: %v", i, err)
		}
	}

	got, err := s.Candles(ctx, "MON-USDC", candleIntervalS, 3)
	if err != nil {
		t.Fatalf("Candles: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d candles, want 3", len(got))
	}
	for i, c := range got {
		if !c.BucketTS.Equal(buckets[i]) {
			t.Errorf("candle %d bucket = %s, want %s (ascending order)", i, c.BucketTS, buckets[i])
		}
		if c.Close != closes[i] {
			t.Errorf("candle %d close = %q, want %q", i, c.Close, closes[i])
		}
	}
}

func TestCandlesLimitReturnsMostRecent(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()

	base := time.Date(2026, 9, 15, 9, 0, 0, 0, time.UTC)
	buckets := []time.Time{base, base.Add(60 * time.Second), base.Add(120 * time.Second)}
	t.Cleanup(func() {
		for _, b := range buckets {
			s.pool.Exec(context.Background(),
				`delete from candles where market = $1 and interval_s = $2 and bucket_ts = $3`,
				"MON-USDC", candleIntervalS, b)
		}
	})
	for _, b := range buckets {
		if _, err := s.pool.Exec(ctx, `
			insert into candles (market, interval_s, bucket_ts, open_px, high_px, low_px, close_px, volume, trade_count)
			values ($1, $2, $3, '1', '1', '1', '1', '1', 1)`,
			"MON-USDC", candleIntervalS, b); err != nil {
			t.Fatalf("seed candle: %v", err)
		}
	}

	got, err := s.Candles(ctx, "MON-USDC", candleIntervalS, 1)
	if err != nil {
		t.Fatalf("Candles: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d candles, want 1", len(got))
	}
	if !got[0].BucketTS.Equal(buckets[2]) {
		t.Errorf("limit=1 returned bucket %s, want the most recent (%s)", got[0].BucketTS, buckets[2])
	}
}

func TestRecentTradesUsesMarketTimeIndex(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()

	hashes := []string{"0x" + randHex(t), "0x" + randHex(t)}
	t.Cleanup(func() {
		for _, h := range hashes {
			s.pool.Exec(context.Background(), `delete from fills where tx_hash = $1`, mustDecodeHash(t, h))
		}
	})

	for i, h := range hashes {
		if _, err := s.pool.Exec(ctx, `
			insert into fills (market, side, px, qty, block_number, tx_hash, log_index)
			values ($1, 'buy', '1', '1', $2, $3, 0)`,
			"MON-USDC", 500+i, mustDecodeHash(t, h)); err != nil {
			t.Fatalf("seed fill %d: %v", i, err)
		}
	}

	got, err := s.RecentTrades(ctx, "MON-USDC", 2)
	if err != nil {
		t.Fatalf("RecentTrades: %v", err)
	}
	if len(got) < 2 {
		t.Fatalf("got %d trades, want at least 2", len(got))
	}
	// Newest (highest block_number) first.
	if got[0].BlockNumber < got[1].BlockNumber {
		t.Errorf("trades not ordered newest-first: %d before %d", got[0].BlockNumber, got[1].BlockNumber)
	}
}

// A landed fill's quote leg is computed from qty*px, not stored -- this
// pins the actual numbers (2 MON at 0.5 USDC/MON = 1 USDC) rather than just
// checking the fields are non-nil, since a UNION ALL type mismatch between
// this branch and account_activity's null placeholders would fail at query
// time, not compile time.
func TestListActivityIncludesTheTradesOtherLeg(t *testing.T) {
	s := testStore(t)
	ctx := context.Background()

	taker := common.HexToAddress("0x3333333333333333333333333333333333333c")
	accountID := time.Now().UnixNano() // unique per run, see TestApplyBlocksMatchesAKnownAccount
	if _, err := s.pool.Exec(ctx,
		`insert into accounts (account_id, smart_account) values ($1, $2) on conflict do nothing`,
		accountID, taker.Bytes()); err != nil {
		t.Fatalf("seed account: %v", err)
	}
	t.Cleanup(func() {
		s.pool.Exec(context.Background(), `delete from accounts where account_id = $1`, accountID)
	})

	h := mustDecodeHash(t, "0x"+randHex(t))
	t.Cleanup(func() {
		s.pool.Exec(context.Background(), `delete from fills where tx_hash = $1`, h)
	})
	if _, err := s.pool.Exec(ctx, `
		insert into fills (account_id, market, side, px, qty, block_number, tx_hash, log_index,
		                    maker_address, taker_address, block_time)
		values ($1, 'MON-USDC', 'sell', 0.5, 2, 999999, $2, 0, $3, $3, now())`,
		accountID, h, taker.Bytes()); err != nil {
		t.Fatalf("seed fill: %v", err)
	}

	got, err := s.ListActivity(ctx, taker.Bytes(), 10)
	if err != nil {
		t.Fatalf("ListActivity: %v", err)
	}
	var found *Activity
	for i := range got {
		if string(got[i].TxHash) == string(h) {
			found = &got[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("no activity row for the seeded fill among %d rows", len(got))
	}
	if found.Asset != "MON" || found.Amount != "2000000000000000000" || found.Decimals != 18 {
		t.Errorf("base leg = %s %s (%d dec), want 2000000000000000000 MON (18 dec)",
			found.Amount, found.Asset, found.Decimals)
	}
	if found.QuoteAsset == nil || *found.QuoteAsset != "USDC" {
		t.Fatalf("quote asset = %v, want USDC", found.QuoteAsset)
	}
	if found.QuoteAmount == nil || *found.QuoteAmount != "1000000" {
		t.Fatalf("quote amount = %v, want 1000000 (1 USDC at 6 decimals)", found.QuoteAmount)
	}
	if found.QuoteDecimals == nil || *found.QuoteDecimals != 6 {
		t.Fatalf("quote decimals = %v, want 6", found.QuoteDecimals)
	}
}
