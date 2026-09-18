-- User-facing rename: WETH-USDC -> ETH-USDC, cbBTC-USDC -> BTC-USDC (same
-- addresses, same real markets seeded in 0007 -- just the display symbol,
-- since "ETH"/"BTC" read better in the app than the wrapped-asset ticker),
-- and XAUt0-USDC dropped from the app (disabled, not deleted, so its
-- already-recorded fills/candles stay queryable rather than orphaned).
--
-- fills.market and candles.market are plain text, not a foreign key to
-- markets.symbol (see migrations/0002's schema), so a rename has to touch
-- all three tables in the same transaction or the already-recorded history
-- for these markets becomes unreachable under the new name.

begin;

update markets set symbol = 'ETH-USDC' where symbol = 'WETH-USDC';
update fills set market = 'ETH-USDC' where market = 'WETH-USDC';
update candles set market = 'ETH-USDC' where market = 'WETH-USDC';

update markets set symbol = 'BTC-USDC' where symbol = 'cbBTC-USDC';
update fills set market = 'BTC-USDC' where market = 'cbBTC-USDC';
update candles set market = 'BTC-USDC' where market = 'cbBTC-USDC';

update markets set enabled = false where symbol = 'XAUt0-USDC';

commit;
