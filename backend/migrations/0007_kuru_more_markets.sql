-- Adds three more real, actively-traded Kuru mainnet markets, found via
-- Kuru's own public API (https://api.kuru.io/api/v1/markets) and then
-- independently verified live on-chain the same way every other market
-- address in this codebase is (getMarketParams() + bestBidAsk() called
-- directly against Monad mainnet, 2026-09-18) -- the API lists ~100
-- deployed markets, the overwhelming majority of which are permissionless
-- meme-coin listings with priceprecision/sizeprecision both zero
-- (misconfigured or never graduated to a real orderbook); these three are
-- the only ones beyond the already-seeded MON-USDC that had real precision
-- and a real, sane bestBidAsk spread confirming genuine liquidity:
--
--   WETH-USDC   ~$2,488/WETH
--   cbBTC-USDC  ~$77,749/cbBTC
--   XAUt0-USDC  ~$4,391/XAUt0 (Tether Gold -- oz of gold, plausible spot price)
--
-- min_qty here is computed with the *correct* formula from the start
-- (minSize / size_precision -- see migrations/0006 for why it isn't
-- minSize / 10^base_dec), so these three don't carry the bug 0006 had to
-- fix retroactively for the first two markets.

begin;

insert into markets
  (symbol, base_token, quote_token, base_dec, quote_dec, venue, venue_ref,
   tick_size, min_qty, price_precision, size_precision, enabled)
values
  ('WETH-USDC',
   '\xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242', -- WETH
   '\x754704Bc059F8C67012fEd69BC8A327a5aafb603', -- USDC
   18, 6, 'kuru', '\xa6afd386135B7d41A6C40C525aBc4A1019b0D132',
   0.01,           -- tickSize(100) / pricePrecision(1e4)
   0.002,          -- minSize(2e7) / sizePrecision(1e10)
   10000, 10000000000, true),

  ('cbBTC-USDC',
   '\xd18B7EC58Cdf4876f6AFebd3Ed1730e4Ce10414b', -- cbBTC
   '\x754704Bc059F8C67012fEd69BC8A327a5aafb603', -- USDC
   8, 6, 'kuru', '\x40C49f171202f91fF5D2FaE34c22Dd2bFDD22aF0',
   0.01,           -- tickSize(100) / pricePrecision(1e4)
   0.000125,       -- minSize(12500) / sizePrecision(1e8)
   10000, 100000000, true),

  ('XAUt0-USDC',
   '\x01bFF41798a0BcF287b996046Ca68b395DbC1071', -- XAUt0 (Tether Gold)
   '\x754704Bc059F8C67012fEd69BC8A327a5aafb603', -- USDC
   6, 6, 'kuru', '\x851145EAeFDC37956b08Da829Fa31722199f3F07',
   0.01,           -- tickSize(100) / pricePrecision(1e4)
   0.002,          -- minSize(2000) / sizePrecision(1e6)
   10000, 1000000, true);

commit;
