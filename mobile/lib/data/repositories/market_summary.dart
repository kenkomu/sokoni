import 'package:decimal/decimal.dart';

import '../api/sokoni_api.dart';

/// How many 1-minute candles back a Home/Markets row's sparkline and change%
/// — 30 minutes, wide enough to draw a shape, narrow enough that one
/// `Future.wait` per market stays cheap on a list of a handful of markets.
const _sparklineWindow = 30;

/// A market plus its recent 1-minute candles, for screens that show a price
/// at a glance (Home, Portfolio) rather than a full chart (that is the trade
/// screen's job). [lastCandle] is null when the market has not traded inside
/// the window yet — shown as "—", never as a fabricated zero.
class MarketSummary {
  const MarketSummary({required this.market, this.candles = const []});

  final MarketInfo market;

  /// Oldest-first, up to [_sparklineWindow] long. Empty, not null, when the
  /// market has no recent trades — every reader below already treats "empty"
  /// and "no data" the same way, so there is no second null-vs-empty state
  /// to keep in sync.
  final List<Candle> candles;

  Candle? get lastCandle => candles.isEmpty ? null : candles.last;

  /// Closing prices for [Sparkline] to draw, oldest first. Null (not empty)
  /// only when there are fewer than two candles — a single point isn't a
  /// line, and a chart drawing this can tell "not enough data yet" from
  /// "genuinely flat" (a real two-point series where both closes are equal)
  /// by whether this is null vs. a same-valued list.
  List<double>? get sparkline =>
      candles.length < 2
          ? null
          : [for (final c in candles) double.parse(c.close)];

  /// Change across the whole fetched window (its first candle's open to its
  /// last candle's close) — "the last [_sparklineWindow] minutes," matching
  /// what the sparkline actually draws, rather than one candle's own
  /// open→close, which was `_sparklineWindow` times narrower than the label
  /// implied. Null when there's nothing to compare.
  Decimal? get changePct {
    if (candles.isEmpty) return null;
    final open = Decimal.parse(candles.first.open);
    if (open == Decimal.zero) return null;
    final close = Decimal.parse(candles.last.close);
    final ratio = (close - open) / open; // Decimal / Decimal → Rational
    final pct =
        ratio.toDecimal(scaleOnInfinitePrecision: 6) * Decimal.fromInt(100);
    return pct.round(scale: 2);
  }
}

/// Fetches every market and its recent candles in parallel. A single
/// market's candle fetch failing (e.g. it has never traded) does not fail
/// the rest — it just gets an empty series, same as a market that traded
/// but not inside this window.
Future<List<MarketSummary>> fetchMarketSummaries(SokoniApi api) async {
  final markets = await api.markets();
  final series = await Future.wait([
    for (final m in markets) _recentCandles(api, m.symbol),
  ]);
  return [
    for (var i = 0; i < markets.length; i++)
      MarketSummary(market: markets[i], candles: series[i]),
  ];
}

Future<List<Candle>> _recentCandles(SokoniApi api, String symbol) async {
  try {
    // The gateway returns newest-first; reverse once here so every reader
    // (sparkline, changePct) can assume oldest-first without re-deriving it.
    final candles = await api.candles(symbol: symbol, limit: _sparklineWindow);
    return candles.reversed.toList();
  } catch (_) {
    return const [];
  }
}
