import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../passkey/cose.dart';
import '../passkey/passkey_service.dart';

/// The phone's side of `backend/internal/gateway`.
///
/// Every operation takes two round trips, because the phone deliberately
/// cannot build one — it holds a passkey and nothing else. [prepareTransfer]
/// asks the gateway to build and sponsor an operation and returns the
/// challenge to sign; [submit] hands the signed assertion back. The phone never
/// sees calldata, a nonce or a gas price, so there is no chain library here to
/// get wrong.
class SokoniApi {
  SokoniApi({required String baseUrl, Dio? dio})
    : _baseUrl = baseUrl,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              contentType: Headers.jsonContentType,
            ),
          );

  final String _baseUrl;
  final Dio _dio;

  Future<GatewayConfig> config() async =>
      GatewayConfig.fromJson(await _get('/v1/config'));

  /// Learn the account this passkey owns. The address is counterfactual:
  /// known, and able to receive funds, before anything has been deployed.
  Future<AccountInfo> registerAccount({
    required String credentialId,
    required PublicKeyCoords publicKey,
  }) async => AccountInfo.fromJson(
    await _post('/v1/accounts', {
      'credentialId': credentialId,
      // Zero-padded to 32 bytes on purpose. A coordinate with a leading zero
      // byte is still a 32-byte coordinate, and the gateway expects all 32.
      'x': publicKey.xHex,
      'y': publicKey.yHex,
    }),
  );

  /// Ask for a transfer. An intent, never calldata.
  ///
  /// [amount] is in the token's base units, as a decimal string. Never a
  /// double — see core/money.dart for why.
  Future<PreparedOp> prepareTransfer({
    required String credentialId,
    required String token,
    required String to,
    required String amount,
  }) async => PreparedOp.fromJson(
    await _post('/v1/ops', {
      'credentialId': credentialId,
      'intent': {
        'kind': 'transfer',
        'token': token,
        'to': to,
        'amount': amount,
      },
    }),
  );

  /// Hand back the signed assertion exactly as [PasskeyAssertion.toJson]
  /// emits it. The gateway accepts that shape as-is, so there is no mapping
  /// layer in between to drift out of step.
  Future<SubmittedOp> submit({
    required String opId,
    required PasskeyAssertion assertion,
  }) async => SubmittedOp.fromJson(
    await _post(
      '/v1/ops/${Uri.encodeComponent(opId)}/submit',
      assertion.toJson(),
    ),
  );

  Future<OpStatus> status(String opId) async =>
      OpStatus.fromJson(await _get('/v1/ops/${Uri.encodeComponent(opId)}'));

  Future<List<MarketInfo>> markets() async {
    final j = await _get('/v1/markets');
    return [
      for (final m in (j['markets'] as List? ?? const []))
        MarketInfo.fromJson(m as Map<String, dynamic>),
    ];
  }

  Future<List<Candle>> candles({
    required String symbol,
    int interval = 60,
    int limit = 100,
  }) async {
    final j = await _get(
      '/v1/markets/${Uri.encodeComponent(symbol)}/candles',
      query: {'interval': interval, 'limit': limit},
    );
    return [
      for (final c in (j['candles'] as List? ?? const []))
        Candle.fromJson(c as Map<String, dynamic>),
    ];
  }

  Future<List<MarketTrade>> recentTrades({
    required String symbol,
    int limit = 50,
  }) async {
    final j = await _get(
      '/v1/markets/${Uri.encodeComponent(symbol)}/trades',
      query: {'limit': limit},
    );
    return [
      for (final t in (j['trades'] as List? ?? const []))
        MarketTrade.fromJson(t as Map<String, dynamic>),
    ];
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
  }) =>
      _send(() => _dio.get<Map<String, dynamic>>(path, queryParameters: query));

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) =>
      _send(() => _dio.post<Map<String, dynamic>>(path, data: body));

  Future<Map<String, dynamic>> _send(
    Future<Response<Map<String, dynamic>>> Function() call,
  ) async {
    try {
      final data = (await call()).data;
      if (data == null) {
        throw const ApiException(
          statusCode: 0,
          code: 'empty_response',
          message: 'The gateway returned an empty response.',
        );
      }
      return data;
    } on DioException catch (e) {
      throw ApiException.fromDio(e, _baseUrl);
    }
  }
}

/// A gateway failure, carrying the message the gateway wrote for a person.
///
/// The gateway's messages name the way out — "not enough USDC, deposit or
/// reduce the amount" — so they are shown as-is rather than being replaced
/// with something generic here.
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.detail,
  });

  factory ApiException.fromDio(DioException e, String baseUrl) {
    final response = e.response;
    final data = response?.data;
    if (response != null && data is Map && data['message'] is String) {
      return ApiException(
        statusCode: response.statusCode ?? 0,
        code: data['error'] as String? ?? 'error',
        message: data['message'] as String,
        detail: data['detail'] as String?,
      );
    }
    if (response != null) {
      return ApiException(
        statusCode: response.statusCode ?? 0,
        code: 'http_${response.statusCode}',
        message:
            'The gateway answered ${response.statusCode} with no explanation.',
      );
    }
    return ApiException(
      statusCode: 0,
      code: 'unreachable',
      message:
          'Could not reach the gateway at $baseUrl. Is it running, and can '
          'this device reach it?',
    );
  }

  final int statusCode;

  /// Stable and machine-readable, e.g. `insufficient_balance`.
  final String code;
  final String message;

  /// The upstream reason, such as a bundler's rejection. For diagnosis, not
  /// for display.
  final String? detail;

  @override
  String toString() =>
      'ApiException($statusCode $code): $message'
      '${detail == null ? '' : ' — $detail'}';
}

class SponsoredToken {
  const SponsoredToken({
    required this.address,
    required this.symbol,
    required this.decimals,
  });

  factory SponsoredToken.fromJson(Map<String, dynamic> j) => SponsoredToken(
    address: _str(j, 'address'),
    symbol: _str(j, 'symbol'),
    decimals: _int(j, 'decimals'),
  );

  final String address;
  final String symbol;
  final int decimals;
}

class GatewayConfig {
  const GatewayConfig({
    required this.chainId,
    required this.entryPoint,
    required this.sponsoredTokens,
  });

  factory GatewayConfig.fromJson(Map<String, dynamic> j) => GatewayConfig(
    chainId: _int(j, 'chainId'),
    entryPoint: _str(j, 'entryPoint'),
    sponsoredTokens: [
      for (final t in (j['sponsoredTokens'] as List? ?? const []))
        SponsoredToken.fromJson(t as Map<String, dynamic>),
    ],
  );

  final int chainId;
  final String entryPoint;
  final List<SponsoredToken> sponsoredTokens;
}

class AccountInfo {
  const AccountInfo({
    required this.credentialId,
    required this.address,
    required this.deployed,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> j) => AccountInfo(
    credentialId: _str(j, 'credentialId'),
    address: _str(j, 'address'),
    deployed: _bool(j, 'deployed'),
  );

  final String credentialId;
  final String address;

  /// False until the first operation deploys it. The address is valid either
  /// way.
  final bool deployed;
}

class PreparedOp {
  const PreparedOp({
    required this.opId,
    required this.challenge,
    required this.sender,
    required this.deploysAccount,
    required this.expiresAt,
  });

  factory PreparedOp.fromJson(Map<String, dynamic> j) => PreparedOp(
    opId: _str(j, 'opId'),
    challenge: _hex32(_str(j, 'challenge')),
    sender: _str(j, 'sender'),
    deploysAccount: _bool(j, 'deploysAccount'),
    expiresAt: DateTime.parse(_str(j, 'expiresAt')),
  );

  final String opId;

  /// The userOpHash: the exact 32 bytes the passkey signs.
  final Uint8List challenge;
  final String sender;
  final bool deploysAccount;

  /// After this the gateway refuses the signature and a new prepare is needed.
  final DateTime expiresAt;
}

class SubmittedOp {
  const SubmittedOp({
    required this.opId,
    required this.userOpHash,
    required this.status,
  });

  factory SubmittedOp.fromJson(Map<String, dynamic> j) => SubmittedOp(
    opId: _str(j, 'opId'),
    userOpHash: _str(j, 'userOpHash'),
    status: _str(j, 'status'),
  );

  final String opId;
  final String userOpHash;
  final String status;
}

class OpStatus {
  const OpStatus({
    required this.opId,
    required this.status,
    this.userOpHash,
    this.txHash,
    this.blockNumber,
    this.reason,
  });

  factory OpStatus.fromJson(Map<String, dynamic> j) => OpStatus(
    opId: _str(j, 'opId'),
    status: _str(j, 'status'),
    userOpHash: j['userOpHash'] as String?,
    txHash: j['txHash'] as String?,
    blockNumber: j['blockNumber'] as int?,
    reason: j['reason'] as String?,
  );

  final String opId;

  /// prepared → submitted → landed | reverted. Or expired, if never signed.
  final String status;
  final String? userOpHash;
  final String? txHash;
  final int? blockNumber;
  final String? reason;

  bool get landed => status == 'landed';

  /// Nothing more will happen to this operation.
  bool get isFinal =>
      status == 'landed' || status == 'reverted' || status == 'expired';
}

class MarketInfo {
  const MarketInfo({
    required this.symbol,
    required this.baseToken,
    required this.quoteToken,
    required this.baseDecimals,
    required this.quoteDecimals,
    required this.tickSize,
    required this.minQty,
  });

  factory MarketInfo.fromJson(Map<String, dynamic> j) => MarketInfo(
    symbol: _str(j, 'symbol'),
    baseToken: _str(j, 'baseToken'),
    quoteToken: _str(j, 'quoteToken'),
    baseDecimals: _int(j, 'baseDecimals'),
    quoteDecimals: _int(j, 'quoteDecimals'),
    tickSize: _str(j, 'tickSize'),
    minQty: _str(j, 'minQty'),
  );

  final String symbol;
  final String baseToken;
  final String quoteToken;
  final int baseDecimals;
  final int quoteDecimals;

  /// Decimal strings, per core/money.dart — never parsed as a double.
  final String tickSize;
  final String minQty;
}

class Candle {
  const Candle({
    required this.bucketTs,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.tradeCount,
  });

  factory Candle.fromJson(Map<String, dynamic> j) => Candle(
    bucketTs: DateTime.parse(_str(j, 'bucketTs')),
    open: _str(j, 'open'),
    high: _str(j, 'high'),
    low: _str(j, 'low'),
    close: _str(j, 'close'),
    volume: _str(j, 'volume'),
    tradeCount: _int(j, 'tradeCount'),
  );

  final DateTime bucketTs;

  /// Decimal strings — never parsed as a double.
  final String open;
  final String high;
  final String low;
  final String close;
  final String volume;
  final int tradeCount;
}

class MarketTrade {
  const MarketTrade({
    required this.fillId,
    required this.side,
    required this.px,
    required this.qty,
    required this.blockNumber,
    required this.txHash,
  });

  factory MarketTrade.fromJson(Map<String, dynamic> j) => MarketTrade(
    fillId: _int(j, 'fillId'),
    side: _str(j, 'side'),
    px: _str(j, 'px'),
    qty: _str(j, 'qty'),
    blockNumber: _int(j, 'blockNumber'),
    txHash: _str(j, 'txHash'),
  );

  final int fillId;

  /// 'buy' | 'sell' — the taker's side, per fills.side in the schema.
  final String side;

  /// Decimal strings — never parsed as a double.
  final String px;
  final String qty;
  final int blockNumber;
  final String txHash;
}

String _str(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v is String) return v;
  throw FormatException('gateway response is missing "$key"');
}

int _int(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v is int) return v;
  throw FormatException('gateway response is missing integer "$key"');
}

bool _bool(Map<String, dynamic> j, String key) {
  final v = j[key];
  if (v is bool) return v;
  throw FormatException('gateway response is missing boolean "$key"');
}

final _hex64 = RegExp(r'^0x[0-9a-fA-F]{64}$');

/// Decodes the 32-byte userOpHash the phone will sign, and refuses anything
/// else rather than sign it. A signature over bytes nobody meant is the one
/// mistake that cannot be taken back.
Uint8List _hex32(String s) {
  if (!_hex64.hasMatch(s)) {
    throw FormatException('challenge must be 0x plus 64 hex digits, got "$s"');
  }
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(s.substring(2 + i * 2, 4 + i * 2), radix: 16);
  }
  return out;
}
