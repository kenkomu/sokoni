import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/data/ws/market_stream.dart';

import '../../support/fake_websocket_channel.dart';

void main() {
  // Pins a real bug found live on-device: a connect-time failure (DNS
  // lookup, connection refused) surfaced as a genuinely unhandled top-level
  // exception, over and over with no backoff, because MarketStream only
  // ever listened for failures via stream.listen's onError/onDone -- which
  // a pure connect-time failure never reaches, since no socket ever opened
  // for onDone to fire for. `ready`'s own doc names this exact failure
  // mode; connect() now catches it explicitly.
  test(
    'a connect-time failure schedules a reconnect instead of going unhandled',
    () async {
      final channels = [
        FakeWebSocketChannel(readyError: Exception('DNS lookup failed')),
      ];
      var next = 0;
      final stream = MarketStream(
        'wss://example.test',
        channelFactory: (_) => channels[next++],
      );
      addTearDown(stream.dispose);

      final events = <MarketEvent>[];
      stream.events.listen(events.add);

      stream.connect();
      // ready's rejection reaches _scheduleReconnect via a microtask, not
      // synchronously within connect() itself.
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single, isA<MarketDisconnected>());
    },
  );

  test(
    'a stream error and a ready failure for the same channel do not double-schedule',
    () async {
      // Exercises both paths firing for one failed connection attempt --
      // _scheduleReconnect has to stay idempotent (see its own
      // _reconnect?.cancel() guard) or this would queue two eventual
      // connect() calls instead of one.
      final channel = FakeWebSocketChannel(readyError: Exception('refused'));
      final stream = MarketStream(
        'wss://example.test',
        channelFactory: (_) => channel,
      );
      addTearDown(stream.dispose);

      final events = <MarketEvent>[];
      stream.events.listen(events.add);

      stream.connect();
      channel.pushError(Exception('stream-level error'));
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
    },
  );
}
