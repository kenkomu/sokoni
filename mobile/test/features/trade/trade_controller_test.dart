import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/core/config.dart';
import 'package:sokoni/data/ws/market_stream.dart';
import 'package:sokoni/features/trade/trade_controller.dart';

import '../../support/fake_gateway.dart';
import '../../support/fake_websocket_channel.dart';

const _config = AppConfig(
  apiBaseUrl: 'http://gateway.test',
  wsUrl: 'ws://gateway.test/v1/stream',
  chainId: AppConfig.monadTestnet,
  relyingPartyId: 'sokoni.app',
);

Map<String, dynamic> _candlesBody({String close = '1.0'}) => {
  'candles': [
    {
      'bucketTs': '2026-09-15T12:00:00Z',
      'open': '1.0',
      'high': '1.0',
      'low': '1.0',
      'close': close,
      'volume': '1.0',
      'tradeCount': 1,
    },
  ],
};

Map<String, dynamic> _tradesBody() => {
  'trades': [
    {
      'fillId': 1,
      'side': 'buy',
      'px': '1.0',
      'qty': '1.0',
      'blockNumber': 100,
      'txHash': '0x${'ab' * 32}',
    },
  ],
};

FakeGateway _gateway({String close = '1.0'}) =>
    FakeGateway()
      ..on(
        'GET',
        '/v1/markets/MON-USDC/candles',
        (_) => (status: 200, body: _candlesBody(close: close)),
      )
      ..on(
        'GET',
        '/v1/markets/MON-USDC/trades',
        (_) => (status: 200, body: _tradesBody()),
      );

void main() {
  test(
    'loadInitial populates candles and trades from the REST snapshot',
    () async {
      final gw = _gateway();
      final c = TradeController(
        config: _config,
        symbol: 'MON-USDC',
        api: gw.api(),
      );

      await c.loadInitial();

      expect(c.state.candles, hasLength(1));
      expect(c.state.trades, hasLength(1));
      expect(c.state.error, isNull);
    },
  );

  test(
    'an increasing-seq message updates state and marks the stream live',
    () async {
      final gw = _gateway();
      final channel = FakeWebSocketChannel();
      final c = TradeController(
        config: _config,
        symbol: 'MON-USDC',
        api: gw.api(),
        stream: MarketStream(
          'ws://gateway.test/v1/stream',
          channelFactory: (_) => channel,
        ),
      );
      await c.loadInitial();
      c.subscribeLive();

      channel.pushFromServer(
        jsonEncode({
          'seq': 1,
          'ch': 'trades:MON-USDC',
          'type': 'trade',
          'data': {
            'fillId': 2,
            'side': 'sell',
            'px': '2.0',
            'qty': '2.0',
            'blockNumber': 200,
            'txHash': '0x${'cd' * 32}',
          },
        }),
      );
      await pumpEventQueue();

      expect(c.state.streamStatus, StreamStatus.live);
      expect(c.state.trades!.first.fillId, 2);
    },
  );

  test('a seq gap re-fetches the REST snapshot', () async {
    final gw = _gateway();
    final channel = FakeWebSocketChannel();
    final c = TradeController(
      config: _config,
      symbol: 'MON-USDC',
      api: gw.api(),
      stream: MarketStream(
        'ws://gateway.test/v1/stream',
        channelFactory: (_) => channel,
      ),
    );
    await c.loadInitial();
    c.subscribeLive();

    // First message establishes seq=1 as the baseline.
    channel.pushFromServer(
      jsonEncode({
        'seq': 1,
        'ch': 'candles:MON-USDC:60',
        'type': 'candle',
        'data': _candlesBody()['candles']![0],
      }),
    );
    await pumpEventQueue();

    // A jump to seq=5 is a gap.
    channel.pushFromServer(
      jsonEncode({
        'seq': 5,
        'ch': 'candles:MON-USDC:60',
        'type': 'candle',
        'data': _candlesBody()['candles']![0],
      }),
    );
    await pumpEventQueue();

    expect(gw.count('GET', '/v1/markets/MON-USDC/candles'), 2);
  });

  test('dispose then a late message does not throw', () async {
    final gw = _gateway();
    final channel = FakeWebSocketChannel();
    final c = TradeController(
      config: _config,
      symbol: 'MON-USDC',
      api: gw.api(),
      stream: MarketStream(
        'ws://gateway.test/v1/stream',
        channelFactory: (_) => channel,
      ),
    );
    await c.loadInitial();
    c.subscribeLive();

    c.dispose();

    expect(
      () => channel.pushFromServer(
        jsonEncode({
          'seq': 1,
          'ch': 'trades:MON-USDC',
          'type': 'trade',
          'data': _tradesBody()['trades']![0],
        }),
      ),
      returnsNormally,
    );
    await pumpEventQueue();
  });
}
