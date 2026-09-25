-- Recent account activity for the Portfolio screen. Unlike fills, this also
-- retains submitted operations that later fail or are still awaiting receipts.

begin;

create table if not exists account_activity (
  op_id          text primary key,
  smart_account  bytea not null,
  kind           text not null,
  market         text not null default '',
  side           text not null default '',
  asset          text not null default '',
  amount         numeric(78,0) not null,
  decimals       smallint not null,
  status         text not null check (status in ('prepared','submitted','landed','reverted','expired','failed')),
  user_op_hash   bytea not null,
  tx_hash        bytea,
  block_number   bigint,
  reason         text not null default '',
  created_at     timestamptz not null,
  updated_at     timestamptz not null
);

create index if not exists account_activity_account_time_idx
  on account_activity (smart_account, created_at desc);
create index if not exists account_activity_account_tx_idx
  on account_activity (smart_account, tx_hash) where tx_hash is not null;

commit;
