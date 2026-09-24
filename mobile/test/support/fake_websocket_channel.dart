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
  /// [readyError], set, makes [ready] reject instead of resolve — a DNS
  /// lookup failure or a refused connection look exactly like this: the
  /// channel exists, but never actually opens, and [stream] never emits
  /// anything at all (no message, no error, no done) because there was
  /// never a socket to carry one.
  FakeWebSocketChannel({Object? readyError}) : _readyError = readyError;

  final Object? _readyError;
  final _incoming = StreamController<dynamic>.broadcast();
  final sentToServer = <dynamic>[];
  var closed = false;

  void pushFromServer(String message) => _incoming.add(message);
  void pushError(Object error) => _incoming.addError(error);

  @override
  Stream get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink(this);

  @override
  Future<void> get ready {
    final err = _readyError;
    return err == null ? Future.value() : Future.error(err);
  }

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
