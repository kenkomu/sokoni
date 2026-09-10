import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sokoni/data/api/sokoni_api.dart';

typedef Reply = ({int status, Object body});

/// Stands in for backend/internal/gateway at the HTTP layer, and records every
/// request so tests can assert what the phone actually put on the wire.
///
/// A route handler may throw instead of replying, which is how a test
/// simulates a gateway that cannot be reached at all.
class FakeGateway implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final _routes = <String, Reply Function(RequestOptions)>{};

  void on(String method, String path, Reply Function(RequestOptions) reply) {
    _routes['$method $path'] = reply;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final route = _routes['${options.method} ${options.path}'];
    if (route == null) {
      return _json(404, {
        'error': 'unknown_route',
        'message': 'no fake for ${options.method} ${options.path}',
      });
    }
    final r = route(options);
    return _json(r.status, r.body);
  }

  @override
  void close({bool force = false}) {}

  /// The body of the last request to [method] [path], as the phone sent it.
  Map<String, dynamic> lastBody(String method, String path) =>
      requests.lastWhere((r) => r.method == method && r.path == path).data
          as Map<String, dynamic>;

  int count(String method, String path) =>
      requests.where((r) => r.method == method && r.path == path).length;

  SokoniApi api() {
    final dio = Dio(BaseOptions(baseUrl: 'http://gateway.test'));
    dio.httpClientAdapter = this;
    return SokoniApi(baseUrl: 'http://gateway.test', dio: dio);
  }
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);
