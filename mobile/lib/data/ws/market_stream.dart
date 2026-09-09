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
  MarketStream(this._url);

  final String _url;
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
    _channel = WebSocketChannel.connect(Uri.parse(_url));
    _sub = _channel!.stream.listen(
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
