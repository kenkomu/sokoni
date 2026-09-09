package chain

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"math/rand/v2"
	"strings"
	"sync"
	"time"
)

// TokenBucket is the global RPC egress limiter — the one protecting the
// resource that actually costs money and that every service shares.
//
// Why it exists, concretely: an unthrottled windowed indexer reached 38.5
// blocks/s against the public endpoint and was killed with
// `-32007 50/second request limit reached`. Note that is 50/s, not the 25 rps
// the Monad docs quote.
//
// Token bucket rather than fixed window for the same reason the gateway uses
// one: it absorbs a burst up to capacity while capping the sustained rate, and
// a backfill is exactly a legitimate burst.
type TokenBucket struct {
	mu         sync.Mutex
	ratePerSec float64
	capacity   float64
	tokens     float64
	lastRefill time.Time
}

func NewTokenBucket(ratePerSec, capacity float64) *TokenBucket {
	if capacity <= 0 {
		capacity = ratePerSec * 2
	}
	return &TokenBucket{
		ratePerSec: ratePerSec,
		capacity:   capacity,
		tokens:     capacity,
		lastRefill: time.Now(),
	}
}

// Take blocks until n tokens are available or ctx is done.
func (b *TokenBucket) Take(ctx context.Context, n float64) error {
	if n > b.capacity {
		return fmt.Errorf("request of %.0f exceeds bucket capacity %.0f", n, b.capacity)
	}
	for {
		b.mu.Lock()
		b.refillLocked()
		if b.tokens >= n {
			b.tokens -= n
			b.mu.Unlock()
			return nil
		}
		deficit := n - b.tokens
		b.mu.Unlock()

		wait := time.Duration(deficit / b.ratePerSec * float64(time.Second))
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
}

func (b *TokenBucket) refillLocked() {
	now := time.Now()
	elapsed := now.Sub(b.lastRefill).Seconds()
	if elapsed <= 0 {
		return
	}
	b.tokens = math.Min(b.capacity, b.tokens+elapsed*b.ratePerSec)
	b.lastRefill = now
}

// IsRateLimited reports whether err is a provider rate-limit signal. These are
// always retryable: the request was rejected, never served.
func IsRateLimited(err error) bool {
	if err == nil {
		return false
	}
	var rpcErr *RPCError
	if errors.As(err, &rpcErr) && rpcErr.Code == -32007 {
		return true
	}
	s := strings.ToLower(err.Error())
	return strings.Contains(s, "request limit") ||
		strings.Contains(s, "rate limit") ||
		strings.Contains(s, "too many requests") ||
		strings.Contains(s, "429")
}

// Retry runs fn with exponential backoff and full jitter.
//
// A rate limit must never take the indexer down: a crash-looping follower falls
// further behind on every restart, which is strictly worse than pausing.
func Retry[T any](ctx context.Context, label string, tries int, fn func(context.Context) (T, error)) (T, error) {
	var zero T
	var lastErr error

	for attempt := range tries {
		v, err := fn(ctx)
		if err == nil {
			return v, nil
		}
		lastErr = err

		// Non-rate-limit errors get a couple of tries in case they're transient,
		// then surface. Rate limits always back off.
		if !IsRateLimited(err) && attempt >= 2 {
			return zero, err
		}

		backoff := min(time.Duration(250*math.Pow(2, float64(attempt)))*time.Millisecond, 8*time.Second)
		wait := time.Duration(rand.Float64() * float64(backoff)) // full jitter: no retry convoys
		slog.Warn("rpc retry", "label", label, "attempt", attempt+1, "of", tries, "wait", wait, "err", err)

		select {
		case <-ctx.Done():
			return zero, ctx.Err()
		case <-time.After(wait):
		}
	}
	return zero, fmt.Errorf("%s: exhausted %d attempts: %w", label, tries, lastErr)
}
