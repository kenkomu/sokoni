import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../core/money.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/passkey/passkey_authenticator.dart';
import '../../data/passkey/passkey_service.dart';
import '../../data/passkey/passkey_signer.dart';

/// What the onboarding screen is currently doing.
enum PasskeyStage { idle, checking, registering, sending }

@immutable
class PasskeyState {
  const PasskeyState({
    this.stage = PasskeyStage.idle,
    this.available,
    this.registered,
    this.account,
    this.config,
    this.lastAssertion,
    this.op,
    this.error,
  });

  final PasskeyStage stage;

  /// Null until checked; false means this device cannot do passkeys at all.
  final bool? available;
  final RegisteredPasskey? registered;

  /// What the gateway is willing to sponsor — chiefly which token, and how
  /// many decimals it has, so the amount field can speak in whole tokens
  /// rather than raw base units. Fetched once at startup; needs no auth.
  final GatewayConfig? config;

  /// The account this passkey owns, as the gateway computed it. Known before
  /// anything is deployed: the address is counterfactual.
  final AccountInfo? account;
  final PasskeyAssertion? lastAssertion;

  /// The latest operation's progress, updated while it is being watched.
  final OpStatus? op;
  final String? error;

  bool get isBusy => stage != PasskeyStage.idle;

  PasskeyState copyWith({
    PasskeyStage? stage,
    bool? available,
    RegisteredPasskey? registered,
    AccountInfo? account,
    GatewayConfig? config,
    PasskeyAssertion? lastAssertion,
    OpStatus? op,
    String? error,
    bool clearError = false,
    bool clearOp = false,
  }) {
    return PasskeyState(
      stage: stage ?? this.stage,
      available: available ?? this.available,
      registered: registered ?? this.registered,
      account: account ?? this.account,
      config: config ?? this.config,
      lastAssertion: lastAssertion ?? this.lastAssertion,
      op: clearOp ? null : (op ?? this.op),
      error: clearError ? null : (error ?? this.error),
    );
  }

  /// The token the app sends today. Phase 1 sponsors exactly one; a real
  /// token picker is Phase 2+ scope, once there is more than one to pick.
  SponsoredToken? get token =>
      (config?.sponsoredTokens.isEmpty ?? true)
          ? null
          : config!.sponsoredTokens.first;
}

/// Drives the Phase 1 loop on a real device: create a passkey, learn the
/// account it owns, and move a token with a fingerprint.
///
/// A plain ChangeNotifier rather than anything clever: this screen exists to
/// prove one thing, and the state it needs fits in one immutable object.
class PasskeyController extends ChangeNotifier {
  PasskeyController({
    required AppConfig config,
    PasskeyAuthenticatorService? service,
    SokoniApi? api,
    this.pollInterval = const Duration(seconds: 1),
    this.pollTimeout = const Duration(seconds: 90),
  }) : _service = service ?? passkeyServiceFor(config),
       _api = api ?? SokoniApi(baseUrl: config.apiBaseUrl);

  final PasskeyAuthenticatorService _service;
  final SokoniApi _api;

  /// How often to ask whether an operation has landed. Monad's blocks are
  /// 300 ms, so a second is patient without being wasteful.
  final Duration pollInterval;

  /// When to stop watching and say "not confirmed yet" instead.
  final Duration pollTimeout;

  PasskeyState _state = const PasskeyState();
  PasskeyState get state => _state;
  bool _disposed = false;

  void _set(PasskeyState next) {
    // A poll can outlive the screen. Notifying a disposed notifier throws.
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> checkAvailability() async {
    _set(_state.copyWith(stage: PasskeyStage.checking, clearError: true));
    final ok = await _service.isAvailable();
    _set(_state.copyWith(stage: PasskeyStage.idle, available: ok));
  }

  /// Loads what the gateway is willing to sponsor. Needs no auth, so this
  /// runs at startup rather than waiting for a passkey — the amount field
  /// can show "TST" instead of a bare number from the very first frame.
  Future<void> loadConfig() async {
    try {
      final config = await _api.config();
      _set(_state.copyWith(config: config));
    } catch (_) {
      // Silent: the amount field just falls back to unlabelled base units,
      // and send() will surface the same failure properly when it matters.
    }
  }

  /// Create a passkey, then learn the account it owns.
  ///
  /// Two steps that fail independently. If the platform made the key but the
  /// gateway was unreachable, the key is kept and [registerAccount] retries
  /// just the second half — prompting for another biometric would leave an
  /// orphaned passkey in the user's password manager.
  Future<void> createPasskey() async {
    _set(_state.copyWith(stage: PasskeyStage.registering, clearError: true));
    try {
      // A fresh user id per signup: the platform replaces any passkey with
      // the same relying party and user id, so a fixed one would silently
      // orphan the previous account's only key on a second signup.
      final userId = _randomUserId();
      final registered = await _service.register(
        userId: userId,
        userName: 'Sokoni ${userId.substring(0, 6)}',
        displayName: 'Sokoni account',
      );
      _set(_state.copyWith(registered: registered));
      await _registerWithGateway(registered);
    } catch (e) {
      _set(
        _state.copyWith(stage: PasskeyStage.idle, error: describeFailure(e)),
      );
    }
  }

  /// Signs back in with a passkey this device already created, instead of
  /// minting another — the gateway's register call is idempotent for the
  /// same credential and key.
  Future<void> useExisting(RegisteredPasskey registered) async {
    _set(_state.copyWith(registered: registered));
    await registerAccount();
  }

  /// Retry the gateway half of registration, without a new passkey.
  Future<void> registerAccount() async {
    final registered = _state.registered;
    if (registered == null) return;
    _set(_state.copyWith(stage: PasskeyStage.registering, clearError: true));
    try {
      await _registerWithGateway(registered);
    } catch (e) {
      _set(
        _state.copyWith(stage: PasskeyStage.idle, error: describeFailure(e)),
      );
    }
  }

  Future<void> _registerWithGateway(RegisteredPasskey registered) async {
    final account = await _api.registerAccount(
      credentialId: registered.credentialId,
      publicKey: registered.publicKey,
    );
    _set(_state.copyWith(stage: PasskeyStage.idle, account: account));
  }

  /// Send [amount] whole tokens — "1.5", not base units — of the gateway's
  /// sponsored token to [to].
  ///
  /// The whole Phase 1 gate in one method: prepare, biometric, submit, watch
  /// it land. The phone never sees calldata, a nonce or a gas price — and
  /// now, thanks to [Money], never sees the token's raw base units either.
  /// A base-unit amount is technically correct and practically useless: on
  /// an 18-decimal token, typing "1" moves 10^-18 of a token, not one.
  Future<void> send({required String to, required String amount}) async {
    final registered = _state.registered;
    if (registered == null || _state.account == null) return;

    _set(
      _state.copyWith(
        stage: PasskeyStage.sending,
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
      final prepared = await _api.prepareTransfer(
        credentialId: registered.credentialId,
        token: token.address,
        to: to,
        amount: baseUnits,
      );

      // The biometric prompt. The challenge is the userOpHash, and the account
      // verifies this exact signature on-chain.
      final assertion = await _service.sign(
        challenge: prepared.challenge,
        allowCredentialIds: [registered.credentialId],
      );
      _set(_state.copyWith(lastAssertion: assertion));

      await _api.submit(opId: prepared.opId, assertion: assertion);
      await _watch(prepared.opId);
    } catch (e) {
      _set(_state.copyWith(stage: PasskeyStage.idle, error: describeAmount(e)));
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
              ? _state.copyWith(stage: PasskeyStage.idle, clearError: true)
              : _state.copyWith(
                stage: PasskeyStage.idle,
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
        // Not a failure: accepted but unconfirmed. Calling it "failed" would be
        // a lie that could make someone send the same money twice.
        _set(
          _state.copyWith(
            stage: PasskeyStage.idle,
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

/// A gateway error already carries a message written for a person; anything
/// else is a platform or parsing failure, which has its own translation.
String describeFailure(Object error) =>
    error is ApiException ? error.message : describePasskeyFailure(error);

/// Adds the one failure [describeFailure] cannot phrase for itself: a
/// malformed amount typed by hand, thrown by [Money.parse] before anything
/// ever reaches the network.
String describeAmount(Object error) =>
    error is FormatException
        ? 'That amount doesn\'t look right — use plain digits and, if '
            'needed, one decimal point.'
        : describeFailure(error);

String _randomUserId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}
