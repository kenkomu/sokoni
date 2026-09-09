// Package id mints Snowflake identifiers: 64-bit, time-sortable, generated
// without coordination between nodes.
//
// Layout: 41 bits ms since epoch | 10 bits node | 12 bits sequence.
// Sorting by creation time is what makes keyset pagination over orders cheap.
//
// This is our *handle* for an order, not its settlement identity. The chain's
// (tx_hash, log_index) is authoritative once an order lands, and the client's
// Idempotency-Key guards the retry. Three identities, three jobs.
package id

import (
	"errors"
	"sync"
	"time"
)

const (
	epochMS  = 1_735_689_600_000 // 2025-01-01T00:00:00Z
	nodeBits = 10
	seqBits  = 12
	maxNode  = -1 ^ (-1 << nodeBits)
	maxSeq   = -1 ^ (-1 << seqBits)
)

var ErrClockRegression = errors.New("clock moved backwards; refusing to mint id")

type Generator struct {
	mu     sync.Mutex
	node   int64
	lastMS int64
	seq    int64
}

func NewGenerator(node int64) (*Generator, error) {
	if node < 0 || node > maxNode {
		return nil, errors.New("node id out of range 0..1023")
	}
	return &Generator{node: node}, nil
}

func (g *Generator) Next() (int64, error) {
	g.mu.Lock()
	defer g.mu.Unlock()

	now := time.Now().UnixMilli()
	if now < g.lastMS {
		// NTP stepped the clock back. Refuse rather than risk a duplicate id;
		// the caller retries and it resolves in milliseconds.
		return 0, ErrClockRegression
	}

	if now == g.lastMS {
		g.seq = (g.seq + 1) & maxSeq
		if g.seq == 0 {
			for now <= g.lastMS {
				now = time.Now().UnixMilli()
			}
		}
	} else {
		g.seq = 0
	}
	g.lastMS = now

	return (now-epochMS)<<(nodeBits+seqBits) | g.node<<seqBits | g.seq, nil
}

func TimestampOf(id int64) time.Time {
	return time.UnixMilli(id>>(nodeBits+seqBits) + epochMS)
}
