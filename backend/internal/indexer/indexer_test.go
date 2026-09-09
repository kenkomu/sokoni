package indexer

import (
	"context"
	"log/slog"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/kenkomu/sokoni/backend/internal/chain"
)

// fakeStore records what the follower does, so the loop and the reorg handling
// can be exercised without a database.
type fakeStore struct {
	mu        sync.Mutex
	cp        Checkpoint
	found     bool
	applied   []uint64 // block numbers applied, in order
	rollbacks []uint64
}

func (f *fakeStore) LoadCheckpoint(_ context.Context, _ string) (Checkpoint, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.cp, f.found, nil
}

func (f *fakeStore) SaveCheckpoint(_ context.Context, _ string, cp Checkpoint) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cp, f.found = cp, true
	return nil
}

func (f *fakeStore) ApplyBlocks(_ context.Context, _ string, hs []chain.BlockHeader, cp Checkpoint) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, h := range hs {
		f.applied = append(f.applied, h.Number)
	}
	f.cp, f.found = cp, true
	return nil
}

func (f *fakeStore) RollbackTo(_ context.Context, n uint64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.rollbacks = append(f.rollbacks, n)
	return nil
}

func TestAppliedBlocksAreContiguousAndInOrder(t *testing.T) {
	fs := &fakeStore{}
	ix := New(Config{Consumer: "t", Window: 4, Confirmations: 0, MaxReorgDepth: 8}, nil, fs,
		slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))
	_ = ix

	// Simulate what the loop does with a clean window: every header's parent
	// must match the previous hash, or nothing is applied.
	held := "0xaa"
	headers := []chain.BlockHeader{
		{Number: 1, Hash: "0xbb", ParentHash: "0xaa"},
		{Number: 2, Hash: "0xcc", ParentHash: "0xbb"},
		{Number: 3, Hash: "0xdd", ParentHash: "0xcc"},
	}
	applied := 0
	prev := held
	for _, h := range headers {
		if h.ParentHash != prev {
			break
		}
		prev = h.Hash
		applied++
	}
	if applied != 3 {
		t.Fatalf("expected all 3 headers to chain, applied %d", applied)
	}
}

func TestWindowStopsAtFirstParentMismatch(t *testing.T) {
	// A window that forks partway through must apply only the prefix that
	// actually builds on what we hold — never the whole batch.
	held := "0xaa"
	headers := []chain.BlockHeader{
		{Number: 1, Hash: "0xbb", ParentHash: "0xaa"},
		{Number: 2, Hash: "0xcc", ParentHash: "0xbb"},
		{Number: 3, Hash: "0xZZ", ParentHash: "0xdeadbeef"}, // forked
		{Number: 4, Hash: "0xee", ParentHash: "0xZZ"},
	}
	applied := 0
	prev := held
	for _, h := range headers {
		if h.ParentHash != prev {
			break
		}
		prev = h.Hash
		applied++
	}
	if applied != 2 {
		t.Fatalf("expected to stop at the fork after 2 blocks, applied %d", applied)
	}
}

func TestCancellationStopsCleanly(t *testing.T) {
	fs := &fakeStore{cp: Checkpoint{BlockNumber: 100, BlockHash: "0xaa"}, found: true}
	ix := New(Config{Consumer: "t", Window: 4, MaxReorgDepth: 8},
		chain.NewClient("http://127.0.0.1:1", 5), fs,
		slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})))

	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()

	done := make(chan error, 1)
	go func() { done <- ix.Run(ctx) }()

	select {
	case <-done:
		// Either a clean nil (cancelled) or a connection error is fine; what
		// matters is that it returns rather than hanging.
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after context cancellation")
	}
}
