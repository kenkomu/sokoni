package gateway

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/kenkomu/sokoni/backend/internal/account"
	"github.com/kenkomu/sokoni/backend/internal/userop"
)

// Credential binds a passkey to the account it owns.
type Credential struct {
	ID        string
	Owner     account.Passkey
	Address   common.Address
	CreatedAt time.Time
}

// Accounts persists credentials. Put inserts if absent and never overwrites:
// rebinding a credential to a different key would hand its account to whoever
// asked second.
type Accounts interface {
	Get(ctx context.Context, credentialID string) (Credential, bool, error)
	Put(ctx context.Context, c Credential) error
}

// Pending is an operation between prepare and landing.
type Pending struct {
	ID           string
	CredentialID string
	// Complete except for the signature. Never rebuilt: see the package doc.
	Op          *userop.UserOperation
	UserOpHash  common.Hash
	ExpiresAt   time.Time
	SubmittedAt time.Time
	BundlerHash common.Hash
}

func (p Pending) Submitted() bool { return !p.SubmittedAt.IsZero() }

// PendingOps holds prepared operations. Phase 1 keeps them in memory, which is
// correct for one gateway instance and wrong for two: a phone that prepares on
// one instance and submits to another gets "no such operation". The system
// design's stateless edge means this moves to Redis before there is a second
// instance — keyed by op id, with the TTL doing the eviction.
type PendingOps interface {
	Put(ctx context.Context, p Pending) error
	Get(ctx context.Context, id string) (Pending, bool, error)
	MarkSubmitted(ctx context.Context, id string, hash common.Hash, at time.Time) error
}

// ------------------------------------------------------------ memory

type MemoryAccounts struct {
	mu   sync.RWMutex
	byID map[string]Credential
}

func NewMemoryAccounts() *MemoryAccounts {
	return &MemoryAccounts{byID: make(map[string]Credential)}
}

func (m *MemoryAccounts) Get(_ context.Context, id string) (Credential, bool, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	c, ok := m.byID[id]
	return c, ok, nil
}

func (m *MemoryAccounts) Put(_ context.Context, c Credential) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, exists := m.byID[c.ID]; !exists {
		m.byID[c.ID] = c
	}
	return nil
}

type MemoryOps struct {
	mu        sync.Mutex
	byID      map[string]Pending
	retention time.Duration
	now       func() time.Time
}

// NewMemoryOps keeps each operation for `retention` after it expires, so a
// phone can still read the outcome of something it submitted just in time.
func NewMemoryOps(retention time.Duration, now func() time.Time) *MemoryOps {
	if now == nil {
		now = time.Now
	}
	return &MemoryOps{byID: make(map[string]Pending), retention: retention, now: now}
}

func (m *MemoryOps) Put(_ context.Context, p Pending) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	// Sweep on write. Without it a long-running gateway grows without bound,
	// one abandoned prepare at a time.
	cutoff := m.now().Add(-m.retention)
	for id, old := range m.byID {
		if old.ExpiresAt.Before(cutoff) {
			delete(m.byID, id)
		}
	}
	m.byID[p.ID] = p
	return nil
}

func (m *MemoryOps) Get(_ context.Context, id string) (Pending, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.byID[id]
	return p, ok, nil
}

func (m *MemoryOps) MarkSubmitted(_ context.Context, id string, hash common.Hash, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.byID[id]
	if !ok {
		return fmt.Errorf("operation %s vanished before it could be marked submitted", id)
	}
	if p.Submitted() {
		return nil
	}
	p.SubmittedAt, p.BundlerHash = at, hash
	// Keep it around for status reads well past the signing window.
	if p.ExpiresAt.Before(at) {
		p.ExpiresAt = at
	}
	m.byID[id] = p
	return nil
}
