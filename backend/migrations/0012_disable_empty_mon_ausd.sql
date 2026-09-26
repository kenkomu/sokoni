-- Disables MON-AUSD. Unlike XAUt0-USDC (0011, re-enabled -- real volume,
-- just a display-scope decision), this market's own bestBidAsk() returns
-- the empty-book sentinels on both sides (bestBid = type(uint256).max,
-- bestAsk = 0), checked live against mainnet on 2026-09-26: zero bids, zero
-- asks. It doesn't appear in Kuru's own markets API discovery list at all,
-- which is consistent with an orderbook nobody is quoting into, not just a
-- low-ranked one. A user hitting Buy or Sell on it today gets a revert (no
-- counterparty), not a fill -- disabling stops that until it has a real
-- book. fills/candles already recorded stay in place, same as 0008's
-- XAUt0 precedent -- history is never deleted for a disabled market.

begin;

update markets set enabled = false where symbol = 'MON-AUSD';

commit;
