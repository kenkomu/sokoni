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
	VenueRef       []byte // the venue's own market/order-book address; nil if unset
	TickSize       string
	MinQty         string
	PricePrecision int64
	SizePrecision  int64
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

	// Nil for fills recorded before migrations/0009 added the column --
	// see its own comment for why those are left unbackfilled.
	BlockTime *time.Time
}

// Activity is one user operation shown in Portfolio. Amount is an integer
// base-unit string with its token scale kept alongside it.
type Activity struct {
	OpID        string
	Account     []byte
	Kind        string
	Market      string
	Side        string
	Asset       string
	Amount      string
	Decimals    int32
	Status      string
	UserOpHash  []byte
	TxHash      []byte
	BlockNumber *int64
	Reason      string
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

func (s *Store) UpsertActivity(ctx context.Context, a Activity) error {
	_, err := s.pool.Exec(ctx, `
		insert into account_activity
		  (op_id, smart_account, kind, market, side, asset, amount, decimals, status,
		   user_op_hash, tx_hash, block_number, reason, created_at, updated_at)
		values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
		on conflict (op_id) do update set
		  status = excluded.status, tx_hash = excluded.tx_hash,
		  block_number = excluded.block_number, reason = excluded.reason,
		  updated_at = excluded.updated_at`,
		a.OpID, a.Account, a.Kind, a.Market, a.Side, a.Asset, a.Amount, a.Decimals,
		a.Status, a.UserOpHash, nullableBytes(a.TxHash), a.BlockNumber, a.Reason,
		a.CreatedAt, a.UpdatedAt)
	return err
}

func nullableBytes(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	return b
}

func (s *Store) UpdateActivity(ctx context.Context, opID, status string, txHash []byte, blockNumber *int64, reason string, at time.Time) error {
	_, err := s.pool.Exec(ctx, `
		update account_activity set status=$2, tx_hash=$3, block_number=$4,
		  reason=$5, updated_at=$6 where op_id=$1`,
		opID, status, nullableBytes(txHash), blockNumber, reason, at)
	return err
}

func (s *Store) ListActivity(ctx context.Context, account []byte, limit int) ([]Activity, error) {
	rows, err := s.pool.Query(ctx, `
		with activity as (
		  select op_id, smart_account, kind, market, side, asset, amount::text as amount,
		         decimals, status, user_op_hash, tx_hash, block_number, reason,
		         created_at, updated_at
		  from account_activity where smart_account=$1
		  union all
		  select 'fill:' || encode(f.tx_hash, 'hex') || ':' || f.log_index::text,
		         a.smart_account, 'trade', f.market,
		         case when f.taker_address=a.smart_account then f.side
		              when f.side='buy' then 'sell' else 'buy' end,
		         split_part(f.market, '-', 1),
		         -- Base-unit scale is the market's own base_dec, not a
		         -- fixed 18 -- cbBTC (BTC-USDC's base token) is 8, and a
		         -- hardcoded 1e18 here would show a BTC trade at 10
		         -- orders of magnitude too large once Money.fromBaseUnits
		         -- divides back out by the real decimals sent alongside it.
		         round(f.qty * power(10, m.base_dec)::numeric)::numeric(78,0)::text,
		         m.base_dec, 'landed', decode('', 'hex'), f.tx_hash, f.block_number, '',
		         f.block_time, f.block_time
		  from fills f
		  join accounts a on a.account_id=f.account_id
		  join markets m on m.symbol=f.market
		  where a.smart_account=$1 and f.block_time is not null
		    and not exists (
		      select 1 from account_activity aa
		      where aa.smart_account=a.smart_account and aa.tx_hash=f.tx_hash
		    )
		)
		select op_id, smart_account, kind, market, side, asset, amount,
		       decimals, status, user_op_hash, tx_hash, block_number, reason,
		       created_at, updated_at
		from activity order by created_at desc limit $2`, account, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Activity
	for rows.Next() {
		var a Activity
		if err := rows.Scan(&a.OpID, &a.Account, &a.Kind, &a.Market, &a.Side, &a.Asset,
			&a.Amount, &a.Decimals, &a.Status, &a.UserOpHash, &a.TxHash,
			&a.BlockNumber, &a.Reason, &a.CreatedAt, &a.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ListMarkets returns every enabled market, ordered for a stable list.
func (s *Store) ListMarkets(ctx context.Context) ([]Market, error) {
	rows, err := s.pool.Query(ctx, `
		select symbol, base_token, quote_token, base_dec, quote_dec, venue, venue_ref,
		       tick_size::text, min_qty::text, price_precision, size_precision
		from markets where enabled order by symbol`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Market
	for rows.Next() {
		var m Market
		if err := rows.Scan(&m.Symbol, &m.BaseToken, &m.QuoteToken, &m.BaseDec, &m.QuoteDec,
			&m.Venue, &m.VenueRef, &m.TickSize, &m.MinQty, &m.PricePrecision, &m.SizePrecision); err != nil {
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
		select base_token, quote_token, base_dec, quote_dec, venue, venue_ref,
		       tick_size::text, min_qty::text, price_precision, size_precision
		from markets where symbol = $1 and enabled`, symbol).
		Scan(&m.BaseToken, &m.QuoteToken, &m.BaseDec, &m.QuoteDec, &m.Venue, &m.VenueRef,
			&m.TickSize, &m.MinQty, &m.PricePrecision, &m.SizePrecision)
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
		       maker_address, taker_address, block_time
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
			&t.MakerAddress, &t.TakerAddress, &t.BlockTime); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
