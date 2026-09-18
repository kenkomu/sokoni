import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/core/config.dart';
import 'package:sokoni/features/markets/market_list_controller.dart';

import '../../support/fake_gateway.dart';

const _config = AppConfig(
  apiBaseUrl: 'http://gateway.test',
  wsUrl: 'ws://gateway.test/v1/stream',
  chainId: AppConfig.monadTestnet,
  relyingPartyId: 'sokoni.app',
);

void main() {
  test('load populates markets with their latest candle', () async {
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
                    'tickSize': '0.000001000000000000',
                    'minQty': '0.000002000000000000',
                  },
                ],
              },
            ),
          )
          ..on(
            'GET',
            '/v1/markets/MON-USDC/candles',
            (_) => (status: 200, body: {'candles': <Object>[]}),
          );
    final c = MarketListController(config: _config, api: gw.api());

    await c.load();

    expect(c.state.summaries, hasLength(1));
    expect(c.state.summaries!.first.market.symbol, 'MON-USDC');
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
    final c = MarketListController(config: _config, api: gw.api());

    await c.load();

    expect(c.state.summaries, isNull);
    expect(c.state.error, 'market data is not available');
    expect(c.state.loading, isFalse);
  });
}
