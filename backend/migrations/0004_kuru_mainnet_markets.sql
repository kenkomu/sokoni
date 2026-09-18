-- Points market data at Monad **mainnet** Kuru, where real trading activity
-- actually exists, while the passkey/paymaster/transfer stack (gateway)
-- keeps running against testnet unchanged. This is a deliberate scope
-- split, not a full mainnet migration: the indexer's own MONAD_RPC_HTTP is
-- set to mainnet at the process level (not in the shared .env, so the
-- gateway is unaffected), and this migration re-points `markets` at the
-- mainnet addresses from internal/chain/addresses.go's original Kuru
-- section -- the same ones 0002 seeded before 0003 redirected MON-USDC to
-- (nonexistent-until-then) testnet values and disabled MON-AUSD.
--
-- Only the indexer reads chain state for these rows (ADR 5, one chain
-- reader) -- this migration does not add a second one, it changes which
-- network the single indexer instance points its `venue_ref` lookups at.

begin;

update markets
set enabled     = true,
    venue_ref   = '\x131A2e70A5b31a517A74b8c567149bc294470Da9',
    quote_token = '\x00000000eFE302BEAA2b3e6e1b18d08D69a9012a'
where symbol = 'MON-AUSD';

update markets
set venue_ref   = '\x065C9d28E428A0db40191a54d33d5b7c71a9C394',
    quote_token = '\x754704Bc059F8C67012fEd69BC8A327a5aafb603'
where symbol = 'MON-USDC';

commit;
