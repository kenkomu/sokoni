// Package indexer follows the chain and maintains projections.
//
// This is the spine. It holds THE ONLY chain read subscription in the platform:
// if every client polled the chain we would need ~3,000 rps against a 50 rps
// ceiling. One follower keeps chain load flat at the block rate no matter how
// many users we have, and everything else reads Postgres/Redis.
//
// Guarantees it must keep:
//   - Ordered.       Blocks are applied strictly in sequence.
//   - Idempotent.    Reprocessing a block writes nothing new (unique constraints).
//   - Reorg-aware.   A parentHash mismatch rolls back rather than corrupting state.
//   - Resumable.     Crash and restart continues from the checkpoint.
//
// PERFORMANCE, measured against the public endpoint on 2026-09-09:
//
//	eth_blockNumber            1149 ms   <- do not call this in a tight loop
//	eth_getBlockByNumber x1     441 ms
//	eth_getBlockByNumber x16     448 ms  <- asking for many at once is ~free
//
// A naive follower (blockNumber + getBlock, serially, per block) ran at
// 1.15 blocks/s against a chain producing 3.3 — it fell behind forever.
// Fetching a window per round trip, refreshing the head only when caught up,
// and checkpointing per window sustains ~22 blocks/s.
package indexer

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/kenkomu/sokoni/backend/internal/chain"
)

// Store is the persistence the follower needs. Kept narrow so the loop can be
// tested against a fake without a database.
type Store interface {
	LoadCheckpoint(ctx context.Context, consumer string) (Checkpoint, bool, error)
	SaveCheckpoint(ctx context.Context, consumer string, cp Checkpoint) error
	// ApplyBlocks writes projections for a window and advances the checkpoint
	// in one transaction, so the checkpoint can never run ahead of the data.
	ApplyBlocks(ctx context.Context, consumer string, headers []chain.BlockHeader, cp Checkpoint) error
	RollbackTo(ctx context.Context, blockNumber uint64) error
}

type Checkpoint struct {
	BlockNumber uint64
	BlockHash   string
}

type Config struct {
	Consumer string
	// Confirmations to stay behind the head. The cheap defence against reorgs.
	Confirmations uint64
	// Window is blocks per round trip. 16 costs about what 1 costs.
	Window uint64
	// StartBlock is used only on a cold start. Zero means "start at head" —
	// backfill is a separate, explicit job, because nobody wants an accidental
	// 103-million-block replay.
	StartBlock uint64
	// MaxReorgDepth beyond which we stop and ask for a human.
	MaxReorgDepth uint64
}

func DefaultConfig() Config {
	return Config{Consumer: "core", Confirmations: 2, Window: 16, MaxReorgDepth: 64}
}

type Indexer struct {
	cfg    Config
	client *chain.Client
	store  Store
	log    *slog.Logger
}

func New(cfg Config, client *chain.Client, store Store, log *slog.Logger) *Indexer {
	if cfg.Window == 0 {
		cfg.Window = 16
	}
	if cfg.Consumer == "" {
		cfg.Consumer = "core"
	}
	if cfg.MaxReorgDepth == 0 {
		cfg.MaxReorgDepth = 64
	}
	return &Indexer{cfg: cfg, client: client, store: store, log: log}
}

var ErrReorgTooDeep = errors.New("reorg deeper than configured limit; halting for review")

// Run follows the chain until ctx is cancelled.
func (ix *Indexer) Run(ctx context.Context) error {
	head, err := ix.client.BlockNumber(ctx)
	if err != nil {
		return fmt.Errorf("initial head: %w", err)
	}

	cp, found, err := ix.store.LoadCheckpoint(ctx, ix.cfg.Consumer)
	if err != nil {
		return fmt.Errorf("load checkpoint: %w", err)
	}
	if !found {
		start := ix.cfg.StartBlock
		if start == 0 {
			start = head
		}
		hs, err := ix.client.HeadersRange(ctx, start, start)
		if err != nil {
			return fmt.Errorf("cold start header: %w", err)
		}
		cp = Checkpoint{BlockNumber: hs[0].Number, BlockHash: hs[0].Hash}
		if err := ix.store.SaveCheckpoint(ctx, ix.cfg.Consumer, cp); err != nil {
			return err
		}
		ix.log.Info("cold start", "block", cp.BlockNumber)
	} else {
		ix.log.Info("resuming", "block", cp.BlockNumber)
	}

	ix.log.Info("following", "head", head, "lag", head-cp.BlockNumber, "window", ix.cfg.Window)

	var processed uint64
	started := time.Now()

	for {
		if err := ctx.Err(); err != nil {
			ix.log.Info("stopped", "block", cp.BlockNumber, "processed", processed)
			return nil
		}

		target := head
		if target > ix.cfg.Confirmations {
			target -= ix.cfg.Confirmations
		} else {
			target = 0
		}

		if target <= cp.BlockNumber {
			// Caught up. Only now do we pay for the expensive head call.
			select {
			case <-ctx.Done():
				ix.log.Info("stopped", "block", cp.BlockNumber, "processed", processed)
				return nil
			case <-time.After(chain.BlockTimeMS * time.Millisecond):
			}
			if head, err = ix.client.BlockNumber(ctx); err != nil {
				if ctx.Err() != nil {
					return nil
				}
				ix.log.Warn("head refresh failed", "err", err)
			}
			continue
		}

		count := min(ix.cfg.Window, target-cp.BlockNumber)
		first := cp.BlockNumber + 1

		headers, err := ix.client.HeadersRange(ctx, first, first+count-1)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("fetch window %d..%d: %w", first, first+count-1, err)
		}

		// The window must be a chain, and must build on what we hold.
		applied := 0
		prev := cp.BlockHash
		for _, h := range headers {
			if h.ParentHash != prev {
				ix.log.Warn("reorg detected", "block", h.Number, "parent", h.ParentHash, "held", prev)
				break
			}
			prev = h.Hash
			applied++
		}

		if applied == 0 {
			if cp, err = ix.rollback(ctx, cp); err != nil {
				return err
			}
			if head, err = ix.client.BlockNumber(ctx); err != nil && ctx.Err() == nil {
				ix.log.Warn("head refresh failed", "err", err)
			}
			continue
		}

		window := headers[:applied]
		last := window[applied-1]
		next := Checkpoint{BlockNumber: last.Number, BlockHash: last.Hash}

		// Projections and checkpoint advance together, so the checkpoint can
		// never claim progress the data does not have.
		if err := ix.store.ApplyBlocks(ctx, ix.cfg.Consumer, window, next); err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("apply blocks %d..%d: %w", first, last.Number, err)
		}
		cp = next
		processed += uint64(applied)

		if processed%200 < uint64(applied) {
			rate := float64(processed) / time.Since(started).Seconds()
			ix.log.Info("progress", "block", cp.BlockNumber, "lag", target-cp.BlockNumber,
				"rate", fmt.Sprintf("%.1f blk/s", rate))
		}
	}
}

// rollback walks back to a block still on the canonical chain. Projections are
// pure functions of the log, so recovery is deleting rows above the common
// ancestor and replaying — there is no compensating logic to get wrong.
func (ix *Indexer) rollback(ctx context.Context, cp Checkpoint) (Checkpoint, error) {
	for depth := uint64(1); depth <= ix.cfg.MaxReorgDepth; depth++ {
		if cp.BlockNumber < depth {
			return Checkpoint{}, ErrReorgTooDeep
		}
		n := cp.BlockNumber - depth

		hs, err := ix.client.HeadersRange(ctx, n, n)
		if err != nil {
			return Checkpoint{}, err
		}
		canonical := hs[0]

		if err := ix.store.RollbackTo(ctx, n); err != nil {
			return Checkpoint{}, err
		}
		next := Checkpoint{BlockNumber: canonical.Number, BlockHash: canonical.Hash}
		if err := ix.store.SaveCheckpoint(ctx, ix.cfg.Consumer, next); err != nil {
			return Checkpoint{}, err
		}
		ix.log.Warn("rolled back", "to", n, "depth", depth)
		return next, nil
	}
	return Checkpoint{}, ErrReorgTooDeep
}
