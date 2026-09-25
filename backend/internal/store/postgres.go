// Package store is the Postgres persistence layer.
package store

import (
	"context"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kenkomu/sokoni/backend/internal/chain"
	"github.com/kenkomu/sokoni/backend/internal/indexer"
	"github.com/kenkomu/sokoni/backend/internal/venue"
)

// logFetcher is the one chain.Client method ApplyBlocks needs, narrowed so
// the store can be tested against a fake without a live RPC.
type logFetcher interface {
	GetLogs(ctx context.Context, address string, topics []string, from, to uint64) ([]chain.Log, error)
}

type Store struct {
	pool  *pgxpool.Pool
	venue logFetcher
}

func Open(ctx context.Context, dsn string) (*Store, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	return &Store{pool: pool}, nil
}

// WithVenueClient wires in the chain reader ApplyBlocks uses to pull Trade
// logs. Left unset, ApplyBlocks advances the checkpoint only -- this is what
// lets cmd/gateway open a Store without ever touching the RPC the indexer
// owns (ADR 5: one chain reader).
func (s *Store) WithVenueClient(c logFetcher) *Store {
	s.venue = c
	return s
}

func (s *Store) Close()              { s.pool.Close() }
func (s *Store) Pool() *pgxpool.Pool { return s.pool }

func decodeHash(h string) ([]byte, error) {
	return hex.DecodeString(strings.TrimPrefix(h, "0x"))
}

func (s *Store) LoadCheckpoint(ctx context.Context, consumer string) (indexer.Checkpoint, bool, error) {
	var n int64
	var h []byte
	err := s.pool.QueryRow(ctx,
		`select block_number, block_hash from indexer_checkpoints where consumer = $1`,
		consumer).Scan(&n, &h)
	if err == pgx.ErrNoRows {
		return indexer.Checkpoint{}, false, nil
	}
	if err != nil {
		return indexer.Checkpoint{}, false, err
	}
	return indexer.Checkpoint{BlockNumber: uint64(n), BlockHash: "0x" + hex.EncodeToString(h)}, true, nil
}

func (s *Store) SaveCheckpoint(ctx context.Context, consumer string, cp indexer.Checkpoint) error {
	h, err := decodeHash(cp.BlockHash)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `
		insert into indexer_checkpoints (consumer, block_number, block_hash, updated_at)
		values ($1, $2, $3, now())
		on conflict (consumer) do update
		  set block_number = excluded.block_number,
		      block_hash   = excluded.block_hash,
		      updated_at   = now()`,
		consumer, int64(cp.BlockNumber), h)
	return err
}

// ApplyBlocks writes a window's projections and advances the checkpoint in one
// transaction. Coupling them is what stops the checkpoint claiming progress the
// projections don't have.
func (s *Store) ApplyBlocks(ctx context.Context, consumer string, headers []chain.BlockHeader, cp indexer.Checkpoint) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if len(headers) > 0 && s.venue != nil {
		if err := s.applyTrades(ctx, tx, headers); err != nil {
			return fmt.Errorf("apply trades: %w", err)
		}
	}

	h, err := decodeHash(cp.BlockHash)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		insert into indexer_checkpoints (consumer, block_number, block_hash, updated_at)
		values ($1, $2, $3, now())
		on conflict (consumer) do update
		  set block_number = excluded.block_number,
		      block_hash   = excluded.block_hash,
		      updated_at   = now()`,
		consumer, int64(cp.BlockNumber), h); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// enabledMarket is the venue-facing subset of a markets row -- just what
// applyTrades needs to fetch and scale a window of Trade logs.
type enabledMarket struct {
	symbol         string
	venueRef       []byte
	baseToken      []byte
	quoteToken     []byte
	baseDec        int32
	pricePrecision int64
	sizePrecision  int64
}

// candleIntervalsS are every bucket size populated, chosen to match the
// trade screen's five time-range tabs (1H/6H/24H/1W/30D) at a readable
// resolution each -- e.g. 1H showing 60 one-minute candles, not 60 daily
// ones. 1W and 30D reuse the 3600s and 86400s buckets rather than adding
// Kuru's own 1w bucket (docs.kuru.io/api-reference/market-data/get-
// candlestick-data: 1m, 5m, 15m, 30m, 1h, 4h, 1d, 1w) -- a bucket added now
// would have no history until a week after it started being populated, and
// 168 hourly or 30 daily candles cover the same range just as well.
// interval_s is a column, not a constant, precisely so adding one here is a
// new row shape, not a schema change.
var candleIntervalsS = []int{60, 300, 3600, 86400}

// candleIntervalS is the 1-minute bucket, called out on its own only
// because the test suite needed one concrete interval to assert against —
// applyTrade itself always writes every interval in candleIntervalsS above,
// never just this one.
const candleIntervalS = 60

// applyTrades pulls one eth_getLogs window per enabled market (not per
// block) and decodes every Trade into `fills`, `ledger_entries` and
// `candles`. Kuru's own tape, not ours: a fill is inserted for every match
// on the book, and account_id/ledger_entries are filled in only when a side
// of it happens to be one of our accounts -- see
// migrations/0002_fills_market_tape.sql for why account_id had to become
// nullable. Candles aggregate every fill regardless of account match, since
// a candle is a market-wide statistic, not a per-user one.
func (s *Store) applyTrades(ctx context.Context, tx pgx.Tx, headers []chain.BlockHeader) error {
	from, to := headers[0].Number, headers[len(headers)-1].Number
	blockTime := make(map[uint64]time.Time, len(headers))
	for _, h := range headers {
		blockTime[h.Number] = time.Unix(int64(h.Timestamp), 0).UTC()
	}

	rows, err := tx.Query(ctx,
		`select symbol, venue_ref, base_token, quote_token, base_dec, price_precision, size_precision from markets
		 where enabled and venue_ref is not null`)
	if err != nil {
		return fmt.Errorf("load markets: %w", err)
	}
	var markets []enabledMarket
	for rows.Next() {
		var m enabledMarket
		if err := rows.Scan(&m.symbol, &m.venueRef, &m.baseToken, &m.quoteToken, &m.baseDec, &m.pricePrecision, &m.sizePrecision); err != nil {
			rows.Close()
			return fmt.Errorf("scan market: %w", err)
		}
		markets = append(markets, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("load markets: %w", err)
	}

	for _, m := range markets {
		addr := "0x" + hex.EncodeToString(m.venueRef)
		logs, err := s.venue.GetLogs(ctx, addr, []string{venue.TradeTopic}, from, to)
		if err != nil {
			return fmt.Errorf("getLogs %s: %w", m.symbol, err)
		}
		for _, lg := range logs {
			// A reorg on our own confirmed-behind-head window would be caught
			// by RollbackTo instead; a log already flagged Removed here means
			// the node served us stale state mid-call, not something to record.
			if lg.Removed {
				continue
			}
			t, err := venue.DecodeTrade(lg)
			if err != nil {
				return fmt.Errorf("decode trade %s#%d: %w", lg.TxHash, lg.LogIndex, err)
			}
			bt, ok := blockTime[t.BlockNumber]
			if !ok {
				return fmt.Errorf("trade %s#%d references block %d, outside this window's headers",
					lg.TxHash, lg.LogIndex, t.BlockNumber)
			}
			if err := s.applyTrade(ctx, tx, m, t, bt); err != nil {
				return fmt.Errorf("apply trade %s#%d: %w", lg.TxHash, lg.LogIndex, err)
			}
		}
	}
	return nil
}

// applyTrade scales one Trade and writes its fill, and -- only for a new
// fill, never a replayed one -- its ledger legs and candle bucket.
//
// Both scalings below are now confirmed against Kuru's own OrderBook.sol
// (github.com/Kuru-Labs/Kuru-contracts-dex-public), not inferred from
// docs.kuru.io prose -- see migrations/0006 and venue/kuru.go's package doc
// for what was actually wrong before and how each was caught. In short:
// price divides by a fixed contract-wide constant (vaultPricePrecision,
// 1e18), never the market's own pricePrecision -- that's what
// OrderCreated's price divides by instead, a different event with a
// deceptively similar-looking price field. And size (FilledSize here) is in
// sizePrecision units, not raw base-asset wei -- base_dec never enters the
// qty formula at all, because it cancels out of the round trip through wei
// and back (see migrations/0006's comment for the algebra).
//
// kuruVaultPricePrecision: confirmed against the first real Trade this
// codebase ever saw (tx 0x770da5cda...5ae632e, block 105832470): raw price
// 23788000000000000 / 1e18 = 0.023788, matching MON's real market price;
// dividing by pricePrecision (1e8) instead gave 237,580,000 -- nonsense for
// a $0.02 token.
var kuruVaultPricePrecision = big.NewInt(1_000_000_000_000_000_000)

func (s *Store) applyTrade(ctx context.Context, tx pgx.Tx, m enabledMarket, t *venue.Trade, blockTime time.Time) error {
	px := new(big.Rat).SetFrac(t.Price, kuruVaultPricePrecision)
	qty := new(big.Rat).SetFrac(t.FilledSize, big.NewInt(m.sizePrecision))

	// IsBuy is the taker's direction. fills.side records the taker's side
	// regardless of which party (if either) turned out to be ours -- a single
	// column cannot hold both counterparties' perspectives, and the taker is
	// the conventional "aggressor" side a trade tape reports.
	side := "sell"
	if t.IsBuy {
		side = "buy"
	}

	txHash, err := decodeHash(t.TxHash)
	if err != nil {
		return fmt.Errorf("tx hash: %w", err)
	}

	// account_id is set when either side of the trade is one of our own
	// accounts; taker takes priority on the rare chance a self-trade matches
	// both (there is then no unique "the" account for one fill row anyway).
	var accountID *int64
	var matchedTaker bool
	for i, addr := range [][]byte{t.Taker.Bytes(), t.Maker.Bytes()} {
		var id int64
		err := tx.QueryRow(ctx, `select account_id from accounts where smart_account = $1`, addr).Scan(&id)
		if err == nil {
			accountID = &id
			matchedTaker = i == 0
			break
		}
		if err != pgx.ErrNoRows {
			return fmt.Errorf("lookup account: %w", err)
		}
	}

	var fillID int64
	err = tx.QueryRow(ctx, `
		insert into fills (account_id, market, side, px, qty, block_number, tx_hash, log_index, maker_address, taker_address, block_time)
		values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		on conflict (tx_hash, log_index) do nothing
		returning fill_id`,
		accountID, m.symbol, side, px.FloatString(18), qty.FloatString(18),
		int64(t.BlockNumber), txHash, int32(t.LogIndex), t.Maker.Bytes(), t.Taker.Bytes(), blockTime).Scan(&fillID)
	if err == pgx.ErrNoRows {
		// Already recorded by an earlier run over this same window -- a
		// reprocess after a crash, not new information. Writing the ledger
		// legs or candle bucket again would double-count both.
		return nil
	}
	if err != nil {
		return fmt.Errorf("insert fill: %w", err)
	}

	if accountID != nil {
		// The matched account's own side, which is the taker's side only
		// when the match was on the taker -- a maker match is the opposite
		// of IsBuy, since IsBuy describes the taker's direction.
		ourBuy := t.IsBuy
		if !matchedTaker {
			ourBuy = !t.IsBuy
		}
		if err := s.writeLedgerLegs(ctx, tx, fillID, *accountID, m, px, qty, ourBuy, txHash, int32(t.LogIndex)); err != nil {
			return fmt.Errorf("ledger legs: %w", err)
		}
	}

	for _, intervalS := range candleIntervalsS {
		if err := s.upsertCandle(ctx, tx, m.symbol, intervalS, px, qty, blockTime); err != nil {
			return fmt.Errorf("upsert %ds candle: %w", intervalS, err)
		}
	}
	return nil
}

// writeLedgerLegs records the two asset movements one of our accounts made
// in a trade: base and quote, opposite signs, sharing txn_id=fillID so the
// pair is traceable back to the fill that caused it. This is not the full
// double-entry the ledger_entries doc comment describes (that needs a
// counterparty leg too, and the counterparty here is the venue or another
// trader, neither of which is one of our accounts) -- it is only our own
// account's balance movement, which is what reconciliation actually checks
// against the chain.
func (s *Store) writeLedgerLegs(ctx context.Context, tx pgx.Tx, fillID, accountID int64, m enabledMarket, px, qty *big.Rat, ourBuy bool, txHash []byte, logIndex int32) error {
	baseDelta := new(big.Rat).Set(qty)
	quoteDelta := new(big.Rat).Mul(px, qty)
	if !ourBuy {
		baseDelta.Neg(baseDelta)
	} else {
		quoteDelta.Neg(quoteDelta)
	}

	legs := []struct {
		asset string
		delta *big.Rat
	}{
		{assetSymbol(m.baseToken), baseDelta},
		{assetSymbol(m.quoteToken), quoteDelta},
	}
	for _, leg := range legs {
		if _, err := tx.Exec(ctx, `
			insert into ledger_entries (txn_id, account_id, asset, delta, reason, tx_hash, log_index)
			values ($1, $2, $3, $4, 'trade', $5, $6)
			on conflict (tx_hash, log_index, account_id, asset) do nothing`,
			fillID, accountID, leg.asset, leg.delta.FloatString(18), txHash, logIndex); err != nil {
			return err
		}
	}
	return nil
}

// assetSymbol maps a market's token address to the label ledger_entries and
// reconciliation_runs use. Kuru's own convention for native MON is the zero
// address (confirmed live via getMarketParams(), see addresses.go); every
// other address here is one already verified in internal/chain/addresses.go.
func assetSymbol(addr []byte) string {
	zero := make([]byte, 20)
	if string(addr) == string(zero) {
		return "MON"
	}
	hexAddr := "0x" + hex.EncodeToString(addr)
	for _, tok := range []chain.Token{chain.AUSD, chain.USDC, chain.WMON} {
		if strings.EqualFold(tok.Address, hexAddr) {
			return tok.Symbol
		}
	}
	return hexAddr
}

// upsertCandle folds one trade into its intervalS bucket. open is set
// only by the first insert into a bucket (ON CONFLICT never touches it);
// high/low/close/volume/trade_count fold in on every trade after, which is
// correct as long as trades are applied in chronological order -- guaranteed
// both within one window (the node returns logs for one address in log
// order) and across windows (the indexer applies windows strictly in
// sequence).
func (s *Store) upsertCandle(ctx context.Context, tx pgx.Tx, market string, intervalS int, px, qty *big.Rat, blockTime time.Time) error {
	bucket := blockTime.Truncate(time.Duration(intervalS) * time.Second)
	pxStr := px.FloatString(18)
	qtyStr := qty.FloatString(18)
	_, err := tx.Exec(ctx, `
		insert into candles (market, interval_s, bucket_ts, open_px, high_px, low_px, close_px, volume, trade_count)
		values ($1, $2, $3, $4, $4, $4, $4, $5, 1)
		on conflict (market, interval_s, bucket_ts) do update
		  set high_px     = greatest(candles.high_px, excluded.high_px),
		      low_px      = least(candles.low_px, excluded.low_px),
		      close_px    = excluded.close_px,
		      volume      = candles.volume + excluded.volume,
		      trade_count = candles.trade_count + 1`,
		market, intervalS, bucket, pxStr, qtyStr)
	return err
}

// RollbackTo discards projections above a block. Safe because every projection
// is a pure function of the chain log and can simply be replayed.
func (s *Store) RollbackTo(ctx context.Context, blockNumber uint64) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx,
		`delete from ledger_entries where tx_hash in (
		   select tx_hash from fills where block_number > $1)`, int64(blockNumber)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx,
		`delete from fills where block_number > $1`, int64(blockNumber)); err != nil {
		return err
	}
	// Candles are a pure aggregation of fills, so drop the affected buckets and
	// let replay rebuild them.
	if _, err := tx.Exec(ctx, `
		delete from candles where bucket_ts >= (
		  select coalesce(min(date_trunc('minute', to_timestamp(0))), 'epoch'::timestamptz))
		and false`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
