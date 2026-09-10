package gateway

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kenkomu/sokoni/backend/internal/account"
	"github.com/kenkomu/sokoni/backend/internal/id"
)

// PostgresAccounts stores credentials in the `accounts` and `credentials`
// tables from 0001_init.sql. Those two are among the few tables that are a
// source of truth rather than a projection — the chain never learns which
// WebAuthn credential id maps to which key — so they are not rebuilt by replay.
type PostgresAccounts struct {
	pool *pgxpool.Pool
	ids  *id.Generator
}

func NewPostgresAccounts(pool *pgxpool.Pool, ids *id.Generator) *PostgresAccounts {
	return &PostgresAccounts{pool: pool, ids: ids}
}

func word32(v *big.Int) []byte {
	out := make([]byte, 32)
	v.FillBytes(out)
	return out
}

func (p *PostgresAccounts) Get(ctx context.Context, credentialID string) (Credential, bool, error) {
	var x, y, addr []byte
	var created time.Time
	err := p.pool.QueryRow(ctx, `
		select c.pubkey_x, c.pubkey_y, a.smart_account, c.created_at
		  from credentials c
		  join accounts a on a.account_id = c.account_id
		 where c.credential_id = $1`,
		[]byte(credentialID)).Scan(&x, &y, &addr, &created)
	if errors.Is(err, pgx.ErrNoRows) {
		return Credential{}, false, nil
	}
	if err != nil {
		return Credential{}, false, err
	}
	return Credential{
		ID:        credentialID,
		Owner:     account.Passkey{X: new(big.Int).SetBytes(x), Y: new(big.Int).SetBytes(y)},
		Address:   common.BytesToAddress(addr),
		CreatedAt: created,
	}, true, nil
}

// Put records the account if new, then attaches the credential to it. Both are
// insert-if-absent, in one transaction, so a retried registration is a no-op
// and a second device's credential lands on the same account row.
func (p *PostgresAccounts) Put(ctx context.Context, c Credential) error {
	accountID, err := p.ids.Next()
	if err != nil {
		return fmt.Errorf("mint account id: %w", err)
	}

	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `
		insert into accounts (account_id, smart_account) values ($1, $2)
		on conflict (smart_account) do nothing`,
		accountID, c.Address.Bytes()); err != nil {
		return fmt.Errorf("insert account: %w", err)
	}

	var existing int64
	if err := tx.QueryRow(ctx,
		`select account_id from accounts where smart_account = $1`,
		c.Address.Bytes()).Scan(&existing); err != nil {
		return fmt.Errorf("find account: %w", err)
	}

	if _, err := tx.Exec(ctx, `
		insert into credentials (credential_id, account_id, pubkey_x, pubkey_y)
		values ($1, $2, $3, $4)
		on conflict (credential_id) do nothing`,
		[]byte(c.ID), existing, word32(c.Owner.X), word32(c.Owner.Y)); err != nil {
		return fmt.Errorf("insert credential: %w", err)
	}

	return tx.Commit(ctx)
}
