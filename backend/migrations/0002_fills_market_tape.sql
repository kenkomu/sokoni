-- Resolves a schema fork surfaced while wiring the Kuru Trade decoder into
-- store.ApplyBlocks: `fills` was designed for user-only fills (account_id not
-- null), but the indexer reads the venue's whole tape -- every match on the
-- book, not just ours. Forcing every row to a known account_id would mean
-- either dropping most of the tape (breaking candles, which must reflect the
-- whole market) or inventing a placeholder account (breaking the ledger
-- invariant that every account_id is real). Neither is acceptable, so
-- `fills` becomes the market-wide tape it actually is: account_id is null
-- for a fill neither side of which is one of our accounts, and the on-chain
-- addresses are kept regardless so a fill is never anonymous even when it
-- isn't ours.

begin;

alter table fills
  alter column account_id drop not null,
  add column maker_address bytea,
  add column taker_address bytea;

comment on column fills.account_id is
  'Set when maker or taker matches accounts.smart_account; null for a fill between two counterparties neither of which is us -- still recorded, because candles are a market-wide aggregate, not a per-user one.';

-- getMarketParams() is per-market and was not on faith: called live against
-- both Kuru markets on Monad mainnet on 2026-09-14 (see internal/chain
-- addresses.go for the block). price_precision divides a Trade/OrderCreated
-- log's raw `price` field to a human decimal; every market seeded below used
-- 1e8, but the column exists because the contract makes it configurable per
-- market, not a network-wide constant.
alter table markets
  add column price_precision bigint not null default 100000000;

insert into markets (symbol, base_token, quote_token, base_dec, quote_dec, venue, venue_ref, tick_size, min_qty, price_precision)
values
  -- Native MON has no ERC-20 address; the zero address is Kuru's own
  -- convention for it (baseAssetAddress came back all zero bytes from
  -- getMarketParams() on both markets).
  ('MON-USDC', '\x0000000000000000000000000000000000000000', '\x754704Bc059F8C67012fEd69BC8A327a5aafb603',
   18, 6, 'kuru', '\x065C9d28E428A0db40191a54d33d5b7c71a9C394',
   0.000001000000000000, 0.000002000000000000, 100000000),
  ('MON-AUSD', '\x0000000000000000000000000000000000000000', '\x00000000eFE302BEAA2b3e6e1b18d08D69a9012a',
   18, 6, 'kuru', '\x131A2e70A5b31a517A74b8c567149bc294470Da9',
   0.000001000000000000, 0.000002000000000000, 100000000)
on conflict (symbol) do nothing;

commit;
