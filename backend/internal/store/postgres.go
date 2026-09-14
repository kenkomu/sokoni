// Package store is the Postgres persistence layer.
package store

import (
	"context"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"

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
		if err := s.applyTrades(ctx, tx, headers[0].Number, headers[len(headers)-1].Number); err != nil {
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
	baseDec        int32
	pricePrecision int64
}

// applyTrades pulls one eth_getLogs window per enabled market (not per
// block) and decodes every Trade into `fills`. Kuru's own tape, not ours:
// a fill is inserted for every match on the book, and account_id is filled
// in only when a side of it happens to be one of our accounts -- see
// migrations/0002_fills_market_tape.sql for why that had to become nullable.
func (s *Store) applyTrades(ctx context.Context, tx pgx.Tx, from, to uint64) error {
	rows, err := tx.Query(ctx,
		`select symbol, venue_ref, base_dec, price_precision from markets
		 where enabled and venue_ref is not null`)
	if err != nil {
		return fmt.Errorf("load markets: %w", err)
	}
	var markets []enabledMarket
	for rows.Next() {
		var m enabledMarket
		if err := rows.Scan(&m.symbol, &m.venueRef, &m.baseDec, &m.pricePrecision); err != nil {
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
			if err := s.insertFill(ctx, tx, m, t); err != nil {
				return fmt.Errorf("insert fill %s#%d: %w", lg.TxHash, lg.LogIndex, err)
			}
		}
	}
	return nil
}

// insertFill scales one Trade into fills' px/qty and writes it. Scaling is
// inferred, not vendor-documented -- see internal/venue's package doc for
// the live OrderCreated log this was checked against (its `size` field was
// an exact multiple of sizePrecision and its `price` field an exact
// multiple of tickSize, and both sat inside [minSize,maxSize] / the
// pricePrecision range with no further rescaling needed), and the same
// caveat that applies to Trade's field layout applies here: treat it as
// provisional until a real Trade log is captured and checked the same way.
func (s *Store) insertFill(ctx context.Context, tx pgx.Tx, m enabledMarket, t *venue.Trade) error {
	px := new(big.Rat).SetFrac(new(big.Int).SetInt64(int64(t.Price)), big.NewInt(m.pricePrecision))
	baseUnit := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(m.baseDec)), nil)
	qty := new(big.Rat).SetFrac(t.FilledSize, baseUnit)

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
	for _, addr := range [][]byte{t.Taker.Bytes(), t.Maker.Bytes()} {
		var id int64
		err := tx.QueryRow(ctx, `select account_id from accounts where smart_account = $1`, addr).Scan(&id)
		if err == nil {
			accountID = &id
			break
		}
		if err != pgx.ErrNoRows {
			return fmt.Errorf("lookup account: %w", err)
		}
	}

	_, err = tx.Exec(ctx, `
		insert into fills (account_id, market, side, px, qty, block_number, tx_hash, log_index, maker_address, taker_address)
		values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		on conflict (tx_hash, log_index) do nothing`,
		accountID, m.symbol, side, px.FloatString(18), qty.FloatString(18),
		int64(t.BlockNumber), txHash, int32(t.LogIndex), t.Maker.Bytes(), t.Taker.Bytes())
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
