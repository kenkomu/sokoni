-- Recent-trades tape has no timestamp: fills only ever carried block_number,
-- even though applyTrade (postgres.go) already looks up the block's real
-- wall-clock time to bucket candles -- it just never wrote it down for the
-- fill itself. Nullable rather than backfilled: re-deriving it for every
-- historical fill means re-fetching each one's block header from chain by
-- number, and the ~11 days of history already recorded is small enough that
-- "no time shown" for those rows is a fair trade against that cost. Every
-- fill from here on gets one.
alter table fills add column if not exists block_time timestamptz;
