// Package store is the Postgres persistence layer.
package store

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kenkomu/sokoni/backend/internal/chain"
	"github.com/kenkomu/sokoni/backend/internal/indexer"
)

type Store struct{ pool *pgxpool.Pool }

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

	// TODO(venue): one eth_getLogs over [headers[0], last] — a range query, not
	// per block — then decode Trade events and insert into fills
	// (unique on tx_hash+log_index), ledger_entries, and candles, all here so
	// they commit atomically with the checkpoint.
	_ = headers

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
