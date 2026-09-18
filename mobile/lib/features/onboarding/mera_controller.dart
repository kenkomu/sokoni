import 'package:flutter/foundation.dart';
import 'package:web3dart/web3dart.dart';

import '../../core/config.dart';
import '../../core/money.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/mera/mera_key_service.dart';

/// What the Mera onboarding screen is currently doing.
enum MeraStage { idle, loadingKey, registering, sending }

@immutable
class MeraState {
  const MeraState({
    this.stage = MeraStage.idle,
    this.key,
    this.account,
    this.config,
    this.op,
    this.error,
  });

  final MeraStage stage;

  /// Null until [MeraController.loadOrCreateKey] runs. Present means this
  /// device already has an owner key, generated one just now.
  final EthPrivateKey? key;

  /// What the gateway is willing to sponsor — same shape and same reason as
  /// PasskeyState.config.
  final GatewayConfig? config;

  /// The account this key owns, as the gateway computed it.
  final MeraAccountInfo? account;

  /// The latest operation's progress, updated while it is being watched.
  final OpStatus? op;
  final String? error;

  bool get isBusy => stage != MeraStage.idle;

  MeraState copyWith({
    MeraStage? stage,
    EthPrivateKey? key,
    MeraAccountInfo? account,
    GatewayConfig? config,
    OpStatus? op,
    String? error,
    bool clearError = false,
    bool clearOp = false,
  }) {
    return MeraState(
      stage: stage ?? this.stage,
      key: key ?? this.key,
      account: account ?? this.account,
      config: config ?? this.config,
      op: clearOp ? null : (op ?? this.op),
      error: clearError ? null : (error ?? this.error),
    );
  }

  /// The token the app sends today — same Phase-1 "sponsors exactly one"
  /// simplification as PasskeyState.token.
  SponsoredToken? get token =>
      (config?.sponsoredTokens.isEmpty ?? true)
          ? null
          : config!.sponsoredTokens.first;
}

/// Drives the Option 2 / Mera loop: find or create an on-device owner key,
/// learn the smart account it owns, and move a token with it — no biometric
/// prompt, no WebAuthn relying-party domain, because the key never leaves
/// [MeraKeyService]'s secure storage and the signature is plain ECDSA. See
/// mera_key_service.dart for why this substitutes for Mera's own PRF-based
/// vault on this build.
class MeraController extends ChangeNotifier {
  MeraController({
    required AppConfig config,
    MeraKeyService? keyService,
    SokoniApi? api,
    this.pollInterval = const Duration(seconds: 1),
    this.pollTimeout = const Duration(seconds: 90),
  }) : _keyService = keyService ?? MeraKeyService(),
       _api = api ?? SokoniApi(baseUrl: config.apiBaseUrl);

  final MeraKeyService _keyService;
  final SokoniApi _api;

  final Duration pollInterval;
  final Duration pollTimeout;

  MeraState _state = const MeraState();
  MeraState get state => _state;
  bool _disposed = false;

  void _set(MeraState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Needs no auth, so this loads immediately, same as PasskeyController.
  Future<void> loadConfig() async {
    try {
      final config = await _api.config();
      _set(_state.copyWith(config: config));
    } catch (_) {
      // Silent, same reasoning as PasskeyController.loadConfig: send()
      // surfaces the same failure properly when it matters.
    }
  }

  /// Loads the existing on-device key, or generates one if this is the first
  /// time. Either way, once a key exists this registers/looks up the account
  /// it owns — the two steps fail independently, same shape as
  /// PasskeyController.createPasskey/registerAccount, for the same reason: a
  /// key generated but not yet registered with the gateway should retry only
  /// the network half, not mint a second key.
  Future<void> loadOrCreateKey() async {
    _set(_state.copyWith(stage: MeraStage.loadingKey, clearError: true));
    try {
      var key = await _keyService.existing();
      key ??= await _keyService.generate();
      _set(_state.copyWith(key: key));
      await _registerWithGateway(key);
    } catch (e) {
      _set(_state.copyWith(stage: MeraStage.idle, error: describeFailure(e)));
    }
  }

  Future<void> _registerWithGateway(EthPrivateKey key) async {
    _set(_state.copyWith(stage: MeraStage.registering, clearError: true));
    try {
      final account = await _api.registerMeraAccount(
        owner: _keyService.addressOf(key),
      );
      _set(_state.copyWith(stage: MeraStage.idle, account: account));
    } catch (e) {
      _set(_state.copyWith(stage: MeraStage.idle, error: describeFailure(e)));
    }
  }

  /// Retry only the gateway half, without touching the key.
  Future<void> registerAccount() async {
    final key = _state.key;
    if (key == null) return;
    await _registerWithGateway(key);
  }

  /// Send [amount] whole tokens of the gateway's sponsored token to [to].
  /// Mirrors PasskeyController.send exactly, but the "biometric prompt" step
  /// is a local ECDSA sign — no platform dialog, because there is no
  /// WebAuthn assertion in this path.
  Future<void> send({required String to, required String amount}) async {
    final key = _state.key;
    if (key == null || _state.account == null) return;

    _set(
      _state.copyWith(
        stage: MeraStage.sending,
        clearError: true,
        clearOp: true,
      ),
    );
    try {
      var token = _state.token;
      if (token == null) {
        await loadConfig();
        token = _state.token;
      }
      if (token == null) {
        throw const ApiException(
          statusCode: 0,
          code: 'no_tokens',
          message:
              'The gateway sponsors no tokens yet, so there is nothing '
              'to send.',
        );
      }

      final owner = _keyService.addressOf(key);
      final baseUnits = Money.parse(amount, token.decimals).units.toString();
      final prepared = await _api.prepareMeraTransfer(
        owner: owner,
        token: token.address,
        to: to,
        amount: baseUnits,
      );

      final signature = _keyService.sign(key, prepared.challenge);

      await _api.submitMera(
        opId: prepared.opId,
        owner: owner,
        signature: signature,
      );
      await _watch(prepared.opId);
    } catch (e) {
      _set(_state.copyWith(stage: MeraStage.idle, error: describeAmount(e)));
    }
  }

  /// Places a market buy or sell on [market] — [amountHuman] is whole units
  /// of whichever asset is being spent (base for a sell, quote for a buy),
  /// scaled here with [decimals] the same way [send] scales a transfer
  /// amount with the token's own decimals, never sent as a human number.
  Future<void> sendTrade({
    required String market,
    required String side,
    required String amountHuman,
    required int decimals,
  }) async {
    final key = _state.key;
    if (key == null || _state.account == null) return;

    _set(
      _state.copyWith(
        stage: MeraStage.sending,
        clearError: true,
        clearOp: true,
      ),
    );
    try {
      final owner = _keyService.addressOf(key);
      final baseUnits = Money.parse(amountHuman, decimals).units.toString();
      final prepared = await _api.prepareMeraTrade(
        owner: owner,
        market: market,
        side: side,
        amount: baseUnits,
      );

      final signature = _keyService.sign(key, prepared.challenge);

      await _api.submitMera(
        opId: prepared.opId,
        owner: owner,
        signature: signature,
      );
      await _watch(prepared.opId);
    } catch (e) {
      _set(_state.copyWith(stage: MeraStage.idle, error: describeAmount(e)));
    }
  }

  Future<void> _watch(String opId) async {
    final deadline = DateTime.now().add(pollTimeout);
    while (!_disposed) {
      final status = await _api.status(opId);
      _set(_state.copyWith(op: status));

      if (status.isFinal) {
        _set(
          status.landed
              ? _state.copyWith(stage: MeraStage.idle, clearError: true)
              : _state.copyWith(
                stage: MeraStage.idle,
                error:
                    status.status == 'reverted'
                        ? 'It reached the chain but reverted'
                            '${status.reason == null ? '' : ': ${status.reason}'}.'
                        : 'It expired before it was signed. Try again.',
              ),
        );
        return;
      }

      if (DateTime.now().isAfter(deadline)) {
        _set(
          _state.copyWith(
            stage: MeraStage.idle,
            error:
                'Submitted, but not confirmed yet. It may still land — '
                'check again before sending it again.',
          ),
        );
        return;
      }
      await Future<void>.delayed(pollInterval);
    }
  }
}

String describeFailure(Object error) =>
    error is ApiException ? error.message : error.toString();

String describeAmount(Object error) =>
    error is FormatException
        ? 'That amount doesn\'t look right — use plain digits and, if '
            'needed, one decimal point.'
        : describeFailure(error);
