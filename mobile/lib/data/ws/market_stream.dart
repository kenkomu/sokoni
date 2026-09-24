import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// The market data stream.
///
/// Every message carries a sequence number. A client that sees a gap must
/// re-request a snapshot rather than render a book it cannot trust — the same
/// recovery discipline the backend's sequencer provides internally.
///
/// Reconnection is exponential with jitter: a venue hiccup must not turn every
/// client into a synchronised thundering herd.
class MarketStream {
  MarketStream(this._url, {WebSocketChannel Function(Uri)? channelFactory})
    : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  final String _url;
  final WebSocketChannel Function(Uri) _channelFactory;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnect;
  int _attempt = 0;
  int? _lastSeq;

  final _events = StreamController<MarketEvent>.broadcast();
  Stream<MarketEvent> get events => _events.stream;

  final Set<String> _channels = {};

  void connect() {
    _reconnect?.cancel();
    final channel = _channelFactory(Uri.parse(_url));
    _channel = channel;
    // A failure before the socket ever opens (DNS lookup, connection
    // refused) doesn't reliably reach .stream.listen's onError below, and
    // .onDone may lag far behind it or never fire at all for a pure
    // connect-time failure — there's no socket to close. Caught here
    // instead, this was surfacing as a genuinely unhandled top-level
    // exception, over and over with no backoff, since nothing ever routed
    // it into _scheduleReconnect. `ready`'s own doc names exactly this
    // failure mode.
    channel.ready.catchError((Object _) {
      if (identical(_channel, channel)) _scheduleReconnect();
    });
    _sub = channel.stream.listen(
      _onMessage,
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
      cancelOnError: true,
    );
    _attempt = 0;
    if (_channels.isNotEmpty) subscribe(_channels.toList());
  }

  void subscribe(List<String> channels) {
    _channels.addAll(channels);
    _channel?.sink.add(jsonEncode({'op': 'sub', 'ch': channels}));
  }

  void _onMessage(dynamic raw) {
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    final seq = map['seq'] as int?;

    // Gap detection. Losing a delta silently is worse than a brief reload.
    if (seq != null && _lastSeq != null && seq != _lastSeq! + 1) {
      _events.add(const MarketEvent.gap());
      _lastSeq = null;
      return;
    }
    if (seq != null) _lastSeq = seq;

    _events.add(MarketEvent.message(map));
  }

  void _scheduleReconnect() {
    _sub?.cancel();
    _channel = null;
    _lastSeq = null;
    // ready's catchError and the stream's onError/onDone can both fire for
    // the same underlying failure — cancelling any timer already in flight
    // keeps a double call from stacking two eventual connect()s.
    _reconnect?.cancel();

    // Full jitter, capped at 30s. Avoids a reconnect convoy after an outage.
    final backoffMs = (500 * (1 << _attempt.clamp(0, 6))).clamp(500, 30000);
    final wait = Duration(milliseconds: backoffMs);
    _attempt++;
    _events.add(const MarketEvent.disconnected());
    _reconnect = Timer(wait, connect);
  }

  Future<void> dispose() async {
    _reconnect?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _events.close();
  }
}

sealed class MarketEvent {
  const MarketEvent();
  const factory MarketEvent.message(Map<String, dynamic> data) = MarketMessage;
  const factory MarketEvent.gap() = MarketGap;
  const factory MarketEvent.disconnected() = MarketDisconnected;
}

class MarketMessage extends MarketEvent {
  const MarketMessage(this.data);
  final Map<String, dynamic> data;
}

class MarketGap extends MarketEvent {
  const MarketGap();
}

class MarketDisconnected extends MarketEvent {
  const MarketDisconnected();
}
