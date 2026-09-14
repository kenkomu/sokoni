// Read-side query methods. postgres.go stays write/checkpoint-only -- this
// file is what the gateway's market-data endpoints read through, and gets
// its own test file (reads_test.go) matching that split.
package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Market is a markets row. TickSize/MinQty come back as decimal strings, cast
// with ::text in the query itself -- money is never a float, on the read
// side any more than the write side (see postgres.go's insertFill/upsertCandle).
type Market struct {
	Symbol         string
	BaseToken      []byte
	QuoteToken     []byte
	BaseDec        int32
	QuoteDec       int32
	Venue          string
	TickSize       string
	MinQty         string
	PricePrecision int64
}

// Candle is one candles row.
type Candle struct {
	BucketTS                       time.Time
	Open, High, Low, Close, Volume string
	TradeCount                     int
}

// Trade is one fills row, as the market-wide tape a recent-trades endpoint
// reads -- not the account-scoped view; account_id is deliberately omitted
// here since this is read by symbol, not by account.
type Trade struct {
	FillID                     int64
	Side                       string
	Px, Qty                    string
	BlockNumber                int64
	TxHash                     []byte
	LogIndex                   int32
	MakerAddress, TakerAddress []byte
}

// ListMarkets returns every enabled market, ordered for a stable list.
func (s *Store) ListMarkets(ctx context.Context) ([]Market, error) {
	rows, err := s.pool.Query(ctx, `
		select symbol, base_token, quote_token, base_dec, quote_dec, venue,
		       tick_size::text, min_qty::text, price_precision
		from markets where enabled order by symbol`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Market
	for rows.Next() {
		var m Market
		if err := rows.Scan(&m.Symbol, &m.BaseToken, &m.QuoteToken, &m.BaseDec, &m.QuoteDec,
			&m.Venue, &m.TickSize, &m.MinQty, &m.PricePrecision); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// MarketBySymbol looks up one market. found=false for an unknown symbol is
// not an error -- callers (the gateway) turn that into a 404 explicitly.
func (s *Store) MarketBySymbol(ctx context.Context, symbol string) (Market, bool, error) {
	var m Market
	m.Symbol = symbol
	err := s.pool.QueryRow(ctx, `
		select base_token, quote_token, base_dec, quote_dec, venue,
		       tick_size::text, min_qty::text, price_precision
		from markets where symbol = $1 and enabled`, symbol).
		Scan(&m.BaseToken, &m.QuoteToken, &m.BaseDec, &m.QuoteDec, &m.Venue, &m.TickSize, &m.MinQty, &m.PricePrecision)
	if err == pgx.ErrNoRows {
		return Market{}, false, nil
	}
	if err != nil {
		return Market{}, false, err
	}
	return m, true, nil
}

// Candles returns the most recent `limit` buckets for a market/interval, in
// ascending bucket order (a chart's natural reading order) -- fetched
// desc+limit (the actual index-friendly query for "the last N") and reversed
// in Go, since only limit rows are ever reordered.
func (s *Store) Candles(ctx context.Context, symbol string, intervalS, limit int) ([]Candle, error) {
	rows, err := s.pool.Query(ctx, `
		select bucket_ts, open_px::text, high_px::text,
		       low_px::text, close_px::text, volume::text, trade_count
		from candles where market = $1 and interval_s = $2
		order by bucket_ts desc limit $3`, symbol, intervalS, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Candle
	for rows.Next() {
		var c Candle
		if err := rows.Scan(&c.BucketTS, &c.Open, &c.High, &c.Low, &c.Close, &c.Volume, &c.TradeCount); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, nil
}

// RecentTrades returns the most recent `limit` fills for a market, newest
// first -- uses fills_market_time_idx on (market, block_number desc).
// fill_id desc breaks ties within one block: a bigserial tracks insertion
// order, which for a single-writer indexer tracks chain order closely enough
// for a UI tape.
func (s *Store) RecentTrades(ctx context.Context, symbol string, limit int) ([]Trade, error) {
	rows, err := s.pool.Query(ctx, `
		select fill_id, side, px::text, qty::text, block_number, tx_hash, log_index,
		       maker_address, taker_address
		from fills where market = $1
		order by block_number desc, fill_id desc limit $2`, symbol, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Trade
	for rows.Next() {
		var t Trade
		if err := rows.Scan(&t.FillID, &t.Side, &t.Px, &t.Qty, &t.BlockNumber, &t.TxHash, &t.LogIndex,
			&t.MakerAddress, &t.TakerAddress); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
