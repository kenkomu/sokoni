import '../api/sokoni_api.dart';
import 'market_summary.dart';

/// Fixed, hand-picked numbers — not randomised — so a screenshot taken now
/// looks the same as one taken later. These never reach a real endpoint and
/// never get mixed into [fetchMarketSummaries]'s output; every screen that
/// renders one is expected to show a visible "Demo data" label alongside it
/// (see [demoModeEnabled]).
List<MarketSummary> demoMarketSummaries() => [
  MarketSummary(
    market: const MarketInfo(
      symbol: 'MON-AUSD',
      baseToken: '0x0000000000000000000000000000000000demo',
      quoteToken: '0x0000000000000000000000000000000000demo',
      baseDecimals: 18,
      quoteDecimals: 6,
      tickSize: '0.000001',
      minQty: '0.000002',
    ),
    candles: _summaryCandles(
      const [0.624, 0.631, 0.618, 0.642, 0.667, 0.659, 0.674, 0.685],
    ),
  ),
  MarketSummary(
    market: const MarketInfo(
      symbol: 'MON-USDC',
      baseToken: '0x0000000000000000000000000000000000demo',
      quoteToken: '0x0000000000000000000000000000000000demo',
      baseDecimals: 18,
      quoteDecimals: 6,
      tickSize: '0.000001',
      minQty: '0.000002',
    ),
    candles: _summaryCandles(
      const [0.702, 0.697, 0.708, 0.684, 0.671, 0.679, 0.655, 0.663],
    ),
  ),
];

/// Turns a list of closes into the tiny candle series [MarketSummary] now
/// wants, the same open→close-chain shape [demoCandleSeries] builds for the
/// coin-detail chart, just shorter — a Home/Markets row's sparkline.
List<Candle> _summaryCandles(List<double> closes) {
  final now = DateTime.now();
  return [
    for (var i = 0; i < closes.length; i++)
      Candle(
        bucketTs: now.subtract(Duration(seconds: (closes.length - i) * 60)),
        open: (i == 0 ? closes[0] : closes[i - 1]).toStringAsFixed(6),
        high: closes[i].toStringAsFixed(6),
        low: closes[i].toStringAsFixed(6),
        close: closes[i].toStringAsFixed(6),
        volume: '0',
        tradeCount: 1,
      ),
  ];
}

// Fixed price paths, not randomised each call — a screenshot taken now looks
// the same as one taken later. Long enough (40 points) for the coin page's
// candlestick chart to read as a real chart rather than a handful of bars.
const _demoSeries = <String, List<double>>{
  'MON-AUSD': [
    0.601,
    0.609,
    0.604,
    0.615,
    0.624,
    0.631,
    0.618,
    0.627,
    0.642,
    0.638,
    0.651,
    0.667,
    0.659,
    0.674,
    0.685,
    0.679,
    0.691,
    0.684,
    0.672,
    0.665,
    0.658,
    0.663,
    0.671,
    0.680,
    0.677,
    0.688,
    0.695,
    0.689,
    0.678,
    0.682,
    0.690,
    0.697,
    0.685,
    0.679,
    0.671,
    0.664,
    0.658,
    0.667,
    0.676,
    0.685,
  ],
  'MON-USDC': [
    0.715,
    0.709,
    0.718,
    0.702,
    0.697,
    0.708,
    0.694,
    0.684,
    0.671,
    0.679,
    0.665,
    0.655,
    0.663,
    0.658,
    0.649,
    0.652,
    0.661,
    0.670,
    0.664,
    0.657,
    0.648,
    0.641,
    0.650,
    0.659,
    0.653,
    0.645,
    0.638,
    0.647,
    0.656,
    0.662,
    0.658,
    0.651,
    0.644,
    0.652,
    0.660,
    0.667,
    0.661,
    0.654,
    0.658,
    0.663,
  ],
};

/// A deterministic walk for any symbol not in [_demoSeries] — seeded by the
/// symbol's own hash, so it's fixed per symbol rather than fixed globally.
List<double> _seriesFor(String symbol) {
  final known = _demoSeries[symbol];
  if (known != null) return known;
  var v = 1.0 + (symbol.hashCode.abs() % 100) / 100;
  var seed = symbol.hashCode;
  int next() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  final series = <double>[v];
  for (var i = 0; i < 39; i++) {
    final step = (next() % 21 - 10) / 1000; // ±1%
    v = (v * (1 + step)).clamp(0.01, double.infinity);
    series.add(v);
  }
  return series;
}

/// A full candle series for one market's coin-detail chart. Six decimals
/// throughout to match [MarketInfo.quoteDecimals] on the two demo markets.
List<Candle> demoCandleSeries(String symbol) {
  final series = _seriesFor(symbol);
  final now = DateTime.now();
  final candles = <Candle>[];
  for (var i = 0; i < series.length; i++) {
    final open = i == 0 ? series[0] * 0.998 : series[i - 1];
    final close = series[i];
    final high = (open > close ? open : close) * 1.002;
    final low = (open < close ? open : close) * 0.998;
    candles.add(
      Candle(
        bucketTs: now.subtract(Duration(seconds: (series.length - i) * 60)),
        open: open.toStringAsFixed(6),
        high: high.toStringAsFixed(6),
        low: low.toStringAsFixed(6),
        close: close.toStringAsFixed(6),
        volume: (500 + (i * 37) % 900).toStringAsFixed(6),
        tradeCount: 3 + (i * 7) % 12,
      ),
    );
  }
  return candles;
}

/// A short, fixed recent-trades tape for the same demo market.
List<MarketTrade> demoTrades(String symbol) {
  final series = _seriesFor(symbol);
  final tail = series.sublist(series.length - 8);
  return [
    for (var i = 0; i < tail.length; i++)
      MarketTrade(
        fillId: i,
        side: i.isEven ? 'buy' : 'sell',
        px: tail[tail.length - 1 - i].toStringAsFixed(6),
        qty: (0.5 + (i * 3) % 10 / 10).toStringAsFixed(6),
        blockNumber: 1000 + i,
        txHash: '0x${'demo'.padRight(64, (i % 10).toString())}'.substring(
          0,
          66,
        ),
      ),
  ];
}
