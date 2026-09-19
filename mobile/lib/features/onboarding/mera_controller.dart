import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../core/money.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/mera/mera_key_service.dart';
import '../../data/signer.dart';

/// What the Mera onboarding screen is currently doing.
enum MeraStage { idle, loadingKey, registering, sending }

@immutable
class MeraState {
  const MeraState({
    this.stage = MeraStage.idle,
    this.signer,
    this.account,
    this.config,
    this.op,
    this.error,
  });

  final MeraStage stage;

  /// Null until [MeraController.loadOrCreateKey] or [MeraController.useWallet]
  /// runs. Either an on-device key ([LocalKeySigner]) or a connected
  /// external wallet — everything past this point (register, send,
  /// sendTrade) talks to [Signer] only and never knows which.
  final Signer? signer;

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
    Signer? signer,
    MeraAccountInfo? account,
    GatewayConfig? config,
    OpStatus? op,
    String? error,
    bool clearError = false,
    bool clearOp = false,
  }) {
    return MeraState(
      stage: stage ?? this.stage,
      signer: signer ?? this.signer,
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

/// Drives the Option 2 / Mera loop: find or create an owner ([Signer]),
/// learn the smart account it owns, and move a token or place a trade with
/// it — no biometric prompt, no WebAuthn relying-party domain, because the
/// signature is plain EIP-191 ECDSA regardless of where the key actually
/// lives. [loadOrCreateKey] gets that key from this device's own secure
/// storage (see mera_key_service.dart for why this substitutes for Mera's
/// own PRF-based vault on this build); [useWallet] gets it from a connected
/// external wallet instead (see data/wallet_connect/). Everything past
/// registration reads [MeraState.signer], never a concrete key type, so
/// which one supplied it is invisible to send/sendTrade/the gateway.
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
      final signer = LocalKeySigner(key, keyService: _keyService);
      _set(_state.copyWith(signer: signer));
      await _registerWithGateway(signer);
    } catch (e) {
      _set(_state.copyWith(stage: MeraStage.idle, error: describeFailure(e)));
    }
  }

  /// The wallet-connect entry point: [signer] is already connected (e.g. a
  /// Reown AppKit session) and ready to sign — this just registers/looks up
  /// the account it owns, the same second half [loadOrCreateKey] runs, so a
  /// connected wallet and an on-device key are indistinguishable from here
  /// on.
  Future<void> useWallet(Signer signer) async {
    _set(_state.copyWith(signer: signer));
    await _registerWithGateway(signer);
  }

  Future<void> _registerWithGateway(Signer signer) async {
    _set(_state.copyWith(stage: MeraStage.registering, clearError: true));
    try {
      final account = await _api.registerMeraAccount(owner: signer.address);
      _set(_state.copyWith(stage: MeraStage.idle, account: account));
    } catch (e) {
      _set(_state.copyWith(stage: MeraStage.idle, error: describeFailure(e)));
    }
  }

  /// Retry only the gateway half, without touching the signer.
  Future<void> registerAccount() async {
    final signer = _state.signer;
    if (signer == null) return;
    await _registerWithGateway(signer);
  }

  /// Send [amount] whole tokens of the gateway's sponsored token to [to].
  /// Mirrors PasskeyController.send exactly, but the "biometric prompt" step
  /// is a local ECDSA sign — no platform dialog, because there is no
  /// WebAuthn assertion in this path.
  Future<void> send({required String to, required String amount}) async {
    final signer = _state.signer;
    if (signer == null || _state.account == null) return;

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

      final baseUnits = Money.parse(amount, token.decimals).units.toString();
      final prepared = await _api.prepareMeraTransfer(
        owner: signer.address,
        token: token.address,
        to: to,
        amount: baseUnits,
      );

      final signature = await signer.sign(prepared.challenge);

      await _api.submitMera(
        opId: prepared.opId,
        owner: signer.address,
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
    final signer = _state.signer;
    if (signer == null || _state.account == null) return;

    _set(
      _state.copyWith(
        stage: MeraStage.sending,
        clearError: true,
        clearOp: true,
      ),
    );
    try {
      final baseUnits = Money.parse(amountHuman, decimals).units.toString();
      final prepared = await _api.prepareMeraTrade(
        owner: signer.address,
        market: market,
        side: side,
        amount: baseUnits,
      );

      final signature = await signer.sign(prepared.challenge);

      await _api.submitMera(
        opId: prepared.opId,
        owner: signer.address,
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
