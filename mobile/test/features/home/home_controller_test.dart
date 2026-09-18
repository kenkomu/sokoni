import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/core/config.dart';
import 'package:sokoni/features/home/home_controller.dart';

import '../../support/fake_gateway.dart';

const _config = AppConfig(
  apiBaseUrl: 'http://gateway.test',
  wsUrl: 'ws://gateway.test/v1/stream',
  chainId: AppConfig.monadTestnet,
  relyingPartyId: 'sokoni.app',
);

void main() {
  test('load populates market summaries with their latest candle', () async {
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
                    'high': '1.05',
                    'low': '0.99',
                    'close': '1.05',
                    'volume': '10',
                    'tradeCount': 1,
                  },
                ],
              },
            ),
          );
    final c = HomeController(config: _config, api: gw.api());

    await c.load();

    expect(c.state.summaries, hasLength(1));
    expect(c.state.summaries!.first.market.symbol, 'MON-AUSD');
    expect(c.state.summaries!.first.lastCandle?.close, '1.05');
    expect(c.state.error, isNull);
    expect(c.state.loading, isFalse);
  });

  test('a gateway failure surfaces its message', () async {
    final gw =
        FakeGateway()..on(
          'GET',
          '/v1/markets',
          (_) => (
            status: 502,
            body: {
              'error': 'no_market_data',
              'message': 'market data is not available',
            },
          ),
        );
    final c = HomeController(config: _config, api: gw.api());

    await c.load();

    expect(c.state.summaries, isNull);
    expect(c.state.error, 'market data is not available');
    expect(c.state.loading, isFalse);
  });
}
