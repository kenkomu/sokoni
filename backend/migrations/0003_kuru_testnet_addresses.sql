-- Fixes a chain-mismatch bug found 2026-09-15: 0002 seeded `markets` with
-- Kuru addresses read back from Monad *mainnet* (see that migration's own
-- comment), but MONAD_RPC_HTTP has always pointed the indexer at *testnet*.
-- Those mainnet addresses carry no bytecode on testnet (eth_getCode ==
-- "0x"), so store.ApplyBlocks has been calling GetLogs against contracts
-- that do not exist there -- every fill/candle/trade query has always
-- returned empty, not because nobody traded, but because nothing was ever
-- being watched. See internal/chain/addresses.go's KuruTestnet* constants
-- for the addresses actually deployed on 10143, confirmed live via
-- eth_getCode and getMarketParams() the same day.

begin;

-- MON-AUSD has no testnet equivalent to redirect to: AUSD itself has no
-- deployed contract on Monad testnet (eth_getCode == "0x" at the mainnet
-- AUSD address). Disabled rather than deleted, so the gap stays visible in
-- the table rather than silently vanishing, and the row is ready to
-- re-enable the moment a testnet AUSD market exists.
update markets
set enabled = false
where symbol = 'MON-AUSD';

-- MON-USDC gets the real testnet market. tick_size/min_qty/price_precision
-- are unchanged from 0002 -- getMarketParams() on the testnet market
-- returned the identical human values (tickSize raw 100 at 1e8 precision =
-- 0.000001; minSize raw 2e12 wei at 18 decimals = 0.000002) -- only the
-- venue_ref (market contract) and quote_token (Kuru's own testnet USDC,
-- not the mainnet USDC address) change.
update markets
set venue_ref   = '\xa241896A7Dbe8a550D2E5fF7A914bB1989ceD2D9',
    quote_token = '\x3bA3d39AFcf8bb994f7964B3e0171Ea2Ba361570'
where symbol = 'MON-USDC';

commit;
