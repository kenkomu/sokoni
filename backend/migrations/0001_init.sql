-- Sokoni schema.
--
-- Design notes that the DDL alone won't tell you:
--  * Money is numeric(38,18) everywhere. Never float, never bigint-of-unknown-scale.
--  * Every projection table is derived from chain events and is safe to DROP and
--    rebuild by replaying from block 0. Nothing here is a source of truth except
--    `accounts` and `orders.idem_key` (user intent, which the chain never sees).
--  * Uniqueness on chain refs is what makes replay idempotent. Do not remove.

begin;

create table if not exists accounts (
  account_id     bigint primary key,
  smart_account  bytea unique,                 -- ERC-4337 account address, null until deployed
  created_at     timestamptz not null default now()
);

-- Registered passkeys. An account may have several (multi-device + recovery).
create table if not exists credentials (
  credential_id  bytea primary key,            -- WebAuthn credential id
  account_id     bigint not null references accounts(account_id),
  pubkey_x       bytea not null,               -- P256 point, verified on-chain via 0x0100
  pubkey_y       bytea not null,
  label          text,
  created_at     timestamptz not null default now()
);
create index if not exists credentials_account_idx on credentials(account_id);

create table if not exists markets (
  symbol       text primary key,               -- 'MON-AUSD'
  base_token   bytea not null,
  quote_token  bytea not null,
  base_dec     smallint not null,
  quote_dec    smallint not null,
  venue        text not null,                  -- adapter key
  venue_ref    bytea,                          -- venue's market address
  tick_size    numeric(38,18) not null,
  min_qty      numeric(38,18) not null,
  enabled      boolean not null default true
);

create table if not exists orders (
  order_id     bigint primary key,             -- snowflake, time-sortable
  account_id   bigint not null references accounts(account_id),
  idem_key     uuid not null,
  market       text not null references markets(symbol),
  side         text not null check (side in ('buy','sell')),
  order_type   text not null check (order_type in ('limit','market')),
  limit_px     numeric(38,18),
  qty          numeric(38,18) not null check (qty > 0),
  filled_qty   numeric(38,18) not null default 0,
  status       text not null check (status in ('new','open','filled','cancelled','failed')),
  tx_hash      bytea,
  fail_reason  text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- THE retry guard. Two taps on a flaky connection must not become two trades.
  constraint orders_idem_uniq unique (account_id, idem_key),
  constraint limit_needs_price check (order_type <> 'limit' or limit_px is not null)
);
create index if not exists orders_account_open_idx on orders(account_id, status) where status in ('new','open');
create index if not exists orders_market_idx on orders(market, created_at desc);

create table if not exists fills (
  fill_id      bigserial primary key,
  order_id     bigint references orders(order_id),
  account_id   bigint not null,
  market       text not null,
  side         text not null,
  px           numeric(38,18) not null,
  qty          numeric(38,18) not null,
  fee          numeric(38,18) not null default 0,
  block_number bigint not null,
  tx_hash      bytea not null,
  log_index    int not null,
  -- chain identity is the settlement identity; replay-safe by construction
  constraint fills_chain_uniq unique (tx_hash, log_index)
);
create index if not exists fills_account_idx on fills(account_id, block_number desc);
create index if not exists fills_market_time_idx on fills(market, block_number desc);

-- Double-entry. Every movement writes >=2 rows whose deltas sum to zero.
create table if not exists ledger_entries (
  entry_id     bigserial primary key,
  txn_id       bigint not null,
  account_id   bigint not null,
  asset        text not null,
  delta        numeric(38,18) not null,
  reason       text not null,                  -- 'trade' | 'deposit' | 'withdrawal' | 'fee'
  tx_hash      bytea,
  log_index    int,
  created_at   timestamptz not null default now(),
  constraint ledger_chain_uniq unique (tx_hash, log_index, account_id, asset)
);
create index if not exists ledger_txn_idx on ledger_entries(txn_id);
create index if not exists ledger_balance_idx on ledger_entries(account_id, asset);

-- Candles, built by streaming aggregation over `fills`.
create table if not exists candles (
  market       text not null,
  interval_s   int  not null,
  bucket_ts    timestamptz not null,
  open_px      numeric(38,18) not null,
  high_px      numeric(38,18) not null,
  low_px       numeric(38,18) not null,
  close_px     numeric(38,18) not null,
  volume       numeric(38,18) not null,
  trade_count  int not null,
  primary key (market, interval_s, bucket_ts)
);

-- Indexer checkpoint. One row per consumer, so a new projection can replay
-- independently without disturbing the others.
create table if not exists indexer_checkpoints (
  consumer     text primary key,
  block_number bigint not null,
  block_hash   bytea not null,                 -- for reorg detection via parent match
  updated_at   timestamptz not null default now()
);

-- Continuous reconciliation results. A non-zero delta outside tolerance halts trading.
create table if not exists reconciliation_runs (
  run_id       bigserial primary key,
  asset        text not null,
  ledger_sum   numeric(38,18) not null,
  chain_balance numeric(38,18) not null,
  delta        numeric(38,18) not null,
  block_number bigint not null,
  status       text not null check (status in ('ok','drift','halted')),
  ran_at       timestamptz not null default now()
);

commit;
