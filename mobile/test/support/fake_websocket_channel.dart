import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A [WebSocketChannel] a test can drive directly: [pushFromServer] feeds a
/// message into [MarketStream.connect]'s listener as if the server sent it,
/// and [sentToServer] records everything the code under test wrote via
/// `sink.add`. No real socket, no [MarketStream] constructor change beyond
/// the `channelFactory` seam it already has.
///
/// `with StreamChannelMixin` supplies cast/pipe/transform/etc. in terms of
/// [stream]/[sink] so this doesn't have to hand-implement every method
/// [WebSocketChannel] inherits from it.
class FakeWebSocketChannel
    with StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final _incoming = StreamController<dynamic>.broadcast();
  final sentToServer = <dynamic>[];
  var closed = false;

  void pushFromServer(String message) => _incoming.add(message);

  @override
  Stream get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink(this);

  @override
  Future<void> get ready => Future.value();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._channel);
  final FakeWebSocketChannel _channel;

  @override
  void add(dynamic data) => _channel.sentToServer.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future close([int? closeCode, String? closeReason]) async {
    _channel.closed = true;
  }

  @override
  Future get done => Future.value();
}
