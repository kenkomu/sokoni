import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/data/repositories/market_summary.dart';

import '../../support/fake_gateway.dart';

void main() {
  test('fetches every market with its latest candle', () async {
    final gw =
        FakeGateway()
          ..on(
            'GET',
            '/v1/markets',
            (_) => (
              status: 200,
              body: {
                'markets': [
                  {
                    'symbol': 'MON-AUSD',
                    'baseToken': '0x0',
                    'quoteToken': '0x1',
                    'baseDecimals': 18,
                    'quoteDecimals': 6,
                    'tickSize': '0.000001',
                    'minQty': '0.000002',
                  },
                ],
              },
            ),
          )
          ..on(
            'GET',
            '/v1/markets/MON-AUSD/candles',
            (_) => (
              status: 200,
              body: {
                'candles': [
                  {
                    'bucketTs': '2026-09-15T00:00:00Z',
                    'open': '1.00',
                    'high': '1.10',
                    'low': '0.95',
                    'close': '1.10',
                    'volume': '100',
                    'tradeCount': 3,
                  },
                ],
              },
            ),
          );

    final summaries = await fetchMarketSummaries(gw.api());

    expect(summaries, hasLength(1));
    expect(summaries.first.market.symbol, 'MON-AUSD');
    expect(summaries.first.lastCandle?.close, '1.10');
    expect(summaries.first.changePct.toString(), '10');
  });

  test('a real multi-candle window populates a sparkline and a whole-window '
      'change%, not just the last candle\'s own open->close', () async {
    final gw =
        FakeGateway()
          ..on(
            'GET',
            '/v1/markets',
            (_) => (
              status: 200,
              body: {
                'markets': [
                  {
                    'symbol': 'MON-USDC',
                    'baseToken': '0x0',
                    'quoteToken': '0x1',
                    'baseDecimals': 18,
                    'quoteDecimals': 6,
                    'tickSize': '0.000001',
                    'minQty': '0.000002',
                  },
                ],
              },
            ),
          )
          ..on(
            'GET',
            '/v1/markets/MON-USDC/candles',
            (_) => (
              status: 200,
              // The gateway answers newest-first.
              body: {
                'candles': [
                  {
                    'bucketTs': '2026-09-15T00:02:00Z',
                    'open': '1.05',
                    'high': '1.12',
                    'low': '1.04',
                    'close': '1.10',
                    'volume': '10',
                    'tradeCount': 1,
                  },
                  {
                    'bucketTs': '2026-09-15T00:01:00Z',
                    'open': '1.00',
                    'high': '1.06',
                    'low': '0.98',
                    'close': '1.05',
                    'volume': '10',
                    'tradeCount': 1,
                  },
                  {
                    'bucketTs': '2026-09-15T00:00:00Z',
                    'open': '0.90',
                    'high': '1.01',
                    'low': '0.90',
                    'close': '1.00',
                    'volume': '10',
                    'tradeCount': 1,
                  },
                ],
              },
            ),
          );

    final summaries = await fetchMarketSummaries(gw.api());

    final req = gw.requests.lastWhere(
      (r) => r.method == 'GET' && r.path == '/v1/markets/MON-USDC/candles',
    );
    expect(req.queryParameters['limit'], 30);
    // Reversed to oldest-first, and every close, not just the latest.
    expect(summaries.first.sparkline, [1.00, 1.05, 1.10]);
    // Whole window: first candle's open (0.90) to last candle's close
    // (1.10) -- not the last candle's own 1.05->1.10 (~4.76%).
    expect(summaries.first.changePct.toString(), '22.22');
  });

  test('a market with no candle yet reports a null change, not zero', () async {
    final gw =
        FakeGateway()
          ..on(
            'GET',
            '/v1/markets',
            (_) => (
              status: 200,
              body: {
                'markets': [
                  {
                    'symbol': 'WMON-AUSD',
                    'baseToken': '0x2',
                    'quoteToken': '0x1',
                    'baseDecimals': 18,
                    'quoteDecimals': 6,
                    'tickSize': '0.000001',
                    'minQty': '0.000002',
                  },
                ],
              },
            ),
          )
          ..on(
            'GET',
            '/v1/markets/WMON-AUSD/candles',
            (_) => (status: 200, body: {'candles': <Object>[]}),
          );

    final summaries = await fetchMarketSummaries(gw.api());

    expect(summaries.first.lastCandle, isNull);
    expect(summaries.first.changePct, isNull);
  });
}
