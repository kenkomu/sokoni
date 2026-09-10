package gateway

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kenkomu/sokoni/backend/internal/id"
)

// Runs against a real Postgres with 0001_init.sql applied. CI provides one;
// locally it skips unless DATABASE_URL is set (`make up && make migrate`).
func postgresAccounts(t *testing.T) *PostgresAccounts {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; CI runs this against a real Postgres")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}
	t.Cleanup(pool.Close)
	gen, err := id.NewGenerator(7)
	if err != nil {
		t.Fatal(err)
	}
	return NewPostgresAccounts(pool, gen)
}

// Random per run, so repeated local runs against the same database never
// collide on the primary keys.
func random(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

func TestPostgresAccountsRoundTrip(t *testing.T) {
	store := postgresAccounts(t)
	ctx := context.Background()

	c := Credential{
		ID:      "pg-" + hex.EncodeToString(random(t, 8)),
		Owner:   gPasskey(),
		Address: common.BytesToAddress(random(t, 20)),
	}
	if err := store.Put(ctx, c); err != nil {
		t.Fatalf("put: %v", err)
	}

	got, found, err := store.Get(ctx, c.ID)
	if err != nil || !found {
		t.Fatalf("get: found=%v err=%v", found, err)
	}
	if got.Address != c.Address || !samePasskey(got.Owner, c.Owner) {
		t.Fatalf("round trip changed the credential: %+v", got)
	}

	// Idempotent: a retried registration is a no-op.
	if err := store.Put(ctx, c); err != nil {
		t.Fatalf("second put must be a no-op: %v", err)
	}

	if _, found, err := store.Get(ctx, "pg-never-registered"); err != nil || found {
		t.Fatalf("unknown credential: found=%v err=%v", found, err)
	}
}

// A second device registers its own credential for the same account address.
// It must attach to the existing account row, not collide with it.
func TestPostgresSecondCredentialJoinsTheSameAccount(t *testing.T) {
	store := postgresAccounts(t)
	ctx := context.Background()
	addr := common.BytesToAddress(random(t, 20))

	first := Credential{ID: "pg-" + hex.EncodeToString(random(t, 8)), Owner: gPasskey(), Address: addr}
	second := Credential{ID: "pg-" + hex.EncodeToString(random(t, 8)), Owner: gPasskey(), Address: addr}
	for _, c := range []Credential{first, second} {
		if err := store.Put(ctx, c); err != nil {
			t.Fatalf("put %s: %v", c.ID, err)
		}
	}
	got, found, err := store.Get(ctx, second.ID)
	if err != nil || !found || got.Address != addr {
		t.Fatalf("second credential: %+v found=%v err=%v", got, found, err)
	}
}
