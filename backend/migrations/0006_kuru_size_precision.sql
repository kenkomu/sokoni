-- Adds size_precision, and corrects min_qty, which was wrong the same way
-- 0002's price_precision comment turns out to have been half wrong.
--
-- Found while seeding the first-ever real trade on MON-USDC (2026-09-18):
-- a Trade event's `filledSize`/`updatedSize` are not raw base-asset wei --
-- they are in the market's sizePrecision units, exactly like the `_size`
-- argument placeAndExecuteMarketSell takes, per Kuru's own OrderBook.sol
-- (_fillOrder emits `_incomingSizeToBeFilled - incomingOrderRemainingSize`,
-- both uint96 in the caller's own size units, never converted to wei before
-- the event fires -- the wei conversion, `_sizePrecisionToBaseAssetPrecision`,
-- only ever runs on msg.value / token-transfer amounts, not on what gets
-- emitted). The human quantity is therefore `filledSize / size_precision`,
-- with base_dec never entering the formula at all (it cancels: wei =
-- filledSize * 10^base_dec / size_precision, then human = wei / 10^base_dec).
--
-- min_qty was seeded in 0002 by dividing minSize by 10^base_dec directly --
-- the same missing-sizePrecision-adjustment bug, applied to a config value
-- instead of a live event. It showed 0.000002 MON as the minimum order size
-- on both markets; the real minimum, confirmed by a market order that
-- reverted with NativeAssetInsufficient below the true value and then
-- succeeded at it, is 200 MON. tick_size is unaffected -- OrderCreated's
-- price field (unlike Trade's) really is pricePrecision-scaled, confirmed
-- against a live log per migration 0002's own package-doc reference, so
-- tick_size = tickSize / price_precision stands as originally computed.
--
-- size_precision = 1e10 confirmed live via getMarketParams() against both
-- venue_ref addresses on Monad mainnet on 2026-09-18, same call pattern
-- 0002 used for price_precision.

begin;

alter table markets
  add column size_precision bigint not null default 10000000000;

update markets
set min_qty = 200
where symbol in ('MON-AUSD', 'MON-USDC');

commit;
