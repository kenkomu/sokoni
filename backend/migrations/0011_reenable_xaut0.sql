-- Re-enables XAUt0-USDC, disabled by migration 0008 for a display-scope
-- reason only ("ETH"/"BTC" read better than wrapped-asset tickers, and
-- XAUt0 had no equally natural rename). The market itself was never a data
-- problem: address, decimals and precision were seeded correctly in 0007
-- and verified live the same way as every other market in this file, and
-- it still shows real, non-meme trading volume on Kuru mainnet
-- (~$1.2M/24h, checked against Kuru's own markets API on 2026-09-26,
-- against ~95 other listed pairs that all have priceprecision=0 and zero
-- volume -- the trap 0007's own comment already warns about).
--
-- fills/candles recorded while it was disabled were never deleted (0008's
-- own comment), so no backfill is needed -- history picks back up exactly
-- where 0008 paused it.

begin;

update markets set enabled = true where symbol = 'XAUt0-USDC';

commit;
