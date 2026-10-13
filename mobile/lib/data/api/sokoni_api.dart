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

  /// Every sponsored token's balanceOf for [address], read live from chain —
  /// there is no ledger for this yet (see CLAUDE.md's Known gaps), so this
  /// is exactly as current as the chain itself, never a cached number.
  Future<AccountBalances> balances(String address) async =>
      AccountBalances.fromJson(await _get('/v1/accounts/$address/balances'));

  Future<List<AccountActivity>> accountActivity(
    String address, {
    int limit = 50,
  }) async {
    final j = await _get(
      '/v1/accounts/${Uri.encodeComponent(address)}/activity',
      query: {'limit': limit},
    );
    return [
      for (final item in (j['activity'] as List? ?? const []))
        AccountActivity.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// Ask the in-app support assistant one question, grounded server-side in
  /// this account's real balances and recent activity (internal/assistant) —
  /// the phone sends only the question text, never the grounding data
  /// itself, since the gateway already has it and building it here would
  /// just be a second, driftable copy of Portfolio's own reads.
  ///
  /// The answer may carry [AssistAnswer.displays] alongside its text: cards
  /// a tool call produced (a balance, an activity list, a market quote) for
  /// the chat UI to render as a widget instead of the model restating the
  /// same data in prose.
  Future<AssistAnswer> assist(String address, String question) async {
    final j = await _post(
      '/v1/accounts/${Uri.encodeComponent(address)}/assistant',
      {'question': question},
    );
    return AssistAnswer.fromJson(j);
  }

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

  /// Ask for a market buy or sell, same intent and amount rules as
  /// [prepareMeraTrade] — the gateway builds the identical Kuru call for a
  /// passkey account.
  Future<PreparedOp> prepareTrade({
    required String credentialId,
    required String market,
    required String side,
    required String amount,
  }) async => PreparedOp.fromJson(
    await _post('/v1/ops', {
      'credentialId': credentialId,
      'intent': {
        'kind': 'trade',
        'market': market,
        'side': side,
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

  // --------------------------------------------------- mera (Option 2) -----
  // Same two-round-trip shape as the passkey path above — prepare, sign,
  // submit — just against /v1/mera/* and keyed by the owner's address
  // instead of a WebAuthn credential id. gateway.PrepareMera/SubmitMera
  // return the same PreparedView/SubmittedView shapes as the passkey
  // endpoints, so PreparedOp/SubmittedOp are reused as-is — but
  // RegisterMera's MeraAccountView carries "owner", not "credentialId", so
  // it gets its own [MeraAccountInfo] rather than forcing AccountInfo's
  // shape onto a response that doesn't have that field.

  /// Learn (or register, on first call) the account this owner key owns.
  Future<MeraAccountInfo> registerMeraAccount({required String owner}) async =>
      MeraAccountInfo.fromJson(
        await _post('/v1/mera/accounts', {'owner': owner}),
      );

  /// Ask for a transfer, same intent shape as [prepareTransfer].
  Future<PreparedOp> prepareMeraTransfer({
    required String owner,
    required String token,
    required String to,
    required String amount,
  }) async => PreparedOp.fromJson(
    await _post('/v1/mera/ops', {
      'owner': owner,
      'intent': {
        'kind': 'transfer',
        'token': token,
        'to': to,
        'amount': amount,
      },
    }),
  );

  /// Ask for a market buy or sell on a Kuru market. [amount] is base units
  /// of whichever asset is being spent — the base asset's wei for a sell,
  /// the quote asset's wei for a buy (see gateway.Intent's doc comment) —
  /// scaled with [MarketInfo.baseDecimals]/[quoteDecimals] on the caller's
  /// side, same "phone never sends a human number" rule as a transfer.
  Future<PreparedOp> prepareMeraTrade({
    required String owner,
    required String market,
    required String side,
    required String amount,
  }) async => PreparedOp.fromJson(
    await _post('/v1/mera/ops', {
      'owner': owner,
      'intent': {
        'kind': 'trade',
        'market': market,
        'side': side,
        'amount': amount,
      },
    }),
  );

  /// Hand back the 65-byte (r, s, v) ECDSA signature as 0x-hex — exactly what
  /// [MeraKeyService.sign] produces, no mapping layer in between.
  Future<SubmittedOp> submitMera({
    required String opId,
    required String owner,
    required Uint8List signature,
  }) async => SubmittedOp.fromJson(
    await _post('/v1/mera/ops/${Uri.encodeComponent(opId)}/submit', {
      'owner': owner,
      'signature': '0x${_hexEncode(signature)}',
    }),
  );

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

class AccountBalance {
  const AccountBalance({required this.token, required this.amount});

  factory AccountBalance.fromJson(Map<String, dynamic> j) => AccountBalance(
    token: SponsoredToken.fromJson(j['token'] as Map<String, dynamic>),
    amount: _str(j, 'amount'),
  );

  final SponsoredToken token;

  /// Base units, as a string — see core/money.dart's Money.fromBaseUnits.
  final String amount;
}

class AccountBalances {
  const AccountBalances({required this.address, required this.balances});

  factory AccountBalances.fromJson(Map<String, dynamic> j) => AccountBalances(
    address: _str(j, 'address'),
    balances: [
      for (final b in (j['balances'] as List? ?? const []))
        AccountBalance.fromJson(b as Map<String, dynamic>),
    ],
  );

  final String address;
  final List<AccountBalance> balances;
}

/// One answer from the "Help and Support" assistant (internal/assistant on
/// the backend). [displays] is whatever tool calls produced along the way —
/// see backend/internal/gateway's DisplayPart doc for the fire-and-forget
/// ("pushAndForget") shape this follows: the gateway decides what cards
/// exist, this is just the wire shape they arrive in.
class AssistAnswer {
  const AssistAnswer({required this.text, required this.displays});

  factory AssistAnswer.fromJson(Map<String, dynamic> j) => AssistAnswer(
    text: _str(j, 'answer'),
    displays: [
      for (final d in (j['displays'] as List? ?? const []))
        AssistDisplay.fromJson(d as Map<String, dynamic>),
    ],
  );

  final String text;
  final List<AssistDisplay> displays;
}

/// One typed card from an assistant answer. [type] picks the widget
/// (assistant_sheet.dart's switch); [data] is that widget's own shape, by
/// convention with the backend tool that produced it, not a schema either
/// side validates.
class AssistDisplay {
  const AssistDisplay({required this.type, required this.data});

  factory AssistDisplay.fromJson(Map<String, dynamic> j) => AssistDisplay(
    type: _str(j, 'type'),
    data: (j['data'] as Map<String, dynamic>?) ?? const {},
  );

  final String type;
  final Map<String, dynamic> data;
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

/// The account a Mera-derived owner key owns — [AccountInfo]'s twin for the
/// Option 2 path, with `owner` (the ECDSA address) standing in for
/// `credentialId`.
class MeraAccountInfo {
  const MeraAccountInfo({
    required this.owner,
    required this.address,
    required this.deployed,
  });

  factory MeraAccountInfo.fromJson(Map<String, dynamic> j) => MeraAccountInfo(
    owner: _str(j, 'owner'),
    address: _str(j, 'address'),
    deployed: _bool(j, 'deployed'),
  );

  final String owner;
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

  /// "MON" out of "MON-AUSD" — for display, where [baseToken] (a contract
  /// address) would be meaningless.
  String get baseSymbol => symbol.split('-').first;

  /// What the base asset actually is, in words — "XAUt0" means nothing to
  /// someone who hasn't met Tether Gold's on-chain ticker. Falls back to the
  /// ticker for any market added without a name here.
  String get baseName => _assetNames[baseSymbol] ?? baseSymbol;

  static const _assetNames = {
    'BTC': 'Bitcoin',
    'ETH': 'Ethereum',
    'MON': 'Monad',
    'XAUt0': 'Tether Gold',
    'AUSD': 'Agora Dollar',
    'USDC': 'USD Coin',
  };
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
    this.blockTime,
  });

  factory MarketTrade.fromJson(Map<String, dynamic> j) {
    final blockTime = j['blockTime'] as String?;
    return MarketTrade(
      fillId: _int(j, 'fillId'),
      side: _str(j, 'side'),
      px: _str(j, 'px'),
      qty: _str(j, 'qty'),
      blockNumber: _int(j, 'blockNumber'),
      txHash: _str(j, 'txHash'),
      blockTime:
          (blockTime == null || blockTime.isEmpty)
              ? null
              : DateTime.parse(blockTime),
    );
  }

  final int fillId;

  /// 'buy' | 'sell' — the taker's side, per fills.side in the schema.
  final String side;

  /// Decimal strings — never parsed as a double.
  final String px;
  final String qty;
  final int blockNumber;
  final String txHash;

  /// Null for fills recorded before the gateway started returning
  /// `blockTime` (backend/migrations/0009) — shown as "—", never guessed.
  final DateTime? blockTime;
}

class AccountActivity {
  const AccountActivity({
    required this.opId,
    required this.kind,
    required this.asset,
    required this.amount,
    required this.decimals,
    required this.status,
    required this.userOpHash,
    required this.createdAt,
    this.market = '',
    this.side = '',
    this.txHash,
    this.reason,
    this.quoteAsset,
    this.quoteAmount,
    this.quoteDecimals,
  });

  factory AccountActivity.fromJson(Map<String, dynamic> j) => AccountActivity(
    opId: _str(j, 'opId'),
    kind: _str(j, 'kind'),
    market: j['market'] as String? ?? '',
    side: j['side'] as String? ?? '',
    asset: j['asset'] as String? ?? '',
    amount: _str(j, 'amount'),
    decimals: _int(j, 'decimals'),
    status: _str(j, 'status'),
    userOpHash: j['userOpHash'] as String? ?? '',
    txHash: j['txHash'] as String?,
    reason: j['reason'] as String?,
    createdAt: DateTime.parse(_str(j, 'createdAt')),
    quoteAsset: j['quoteAsset'] as String?,
    quoteAmount: j['quoteAmount'] as String?,
    quoteDecimals: j['quoteDecimals'] as int?,
  );

  final String opId;
  final String kind;
  final String market;
  final String side;
  final String asset;
  final String amount;
  final int decimals;
  final String status;
  final String userOpHash;
  final String? txHash;
  final String? reason;
  final DateTime createdAt;

  /// The trade's other leg — what was received on a sell, what was spent
  /// on a buy. Null until a real fill exists for the operation (a
  /// prepared/submitted market order has no output size yet — see the
  /// gateway's own ActivityView.QuoteAsset doc).
  final String? quoteAsset;
  final String? quoteAmount;
  final int? quoteDecimals;
}

String _hexEncode(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

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
