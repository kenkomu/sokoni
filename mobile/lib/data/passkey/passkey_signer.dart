import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:passkeys/authenticator.dart';

import '../../core/config.dart';
import '../api/sokoni_api.dart';
import '../signer.dart';
import 'cose.dart';
import 'passkey_authenticator.dart';
import 'passkey_service.dart';

/// A [Signer] backed by a passkey: the key lives in the platform
/// authenticator and every operation is authorised with a fingerprint (or
/// face) prompt. Registers and submits through `/v1/ops`, where the gateway
/// verifies the WebAuthn assertion check-for-check against WebAuthn.sol
/// before the bundler sees it — see CLAUDE.md's "Gateway" section.
class PasskeySigner implements Signer {
  PasskeySigner(
    this.passkey, {
    required AppConfig config,
    PasskeyAuthenticatorService? service,
  }) : _service = service ?? passkeyServiceFor(config);

  final RegisteredPasskey passkey;
  final PasskeyAuthenticatorService _service;

  String get credentialId => passkey.credentialId;

  @override
  Future<MeraAccountInfo> register(SokoniApi api) async {
    final account = await api.registerAccount(
      credentialId: passkey.credentialId,
      publicKey: passkey.publicKey,
    );
    // The rest of the app keys an account by "owner"; for a passkey that is
    // its credential id, the same identity AppShell already shows.
    return MeraAccountInfo(
      owner: account.credentialId,
      address: account.address,
      deployed: account.deployed,
    );
  }

  @override
  Future<PreparedOp> prepareTransfer(
    SokoniApi api, {
    required String token,
    required String to,
    required String amount,
  }) => api.prepareTransfer(
    credentialId: credentialId,
    token: token,
    to: to,
    amount: amount,
  );

  @override
  Future<PreparedOp> prepareTrade(
    SokoniApi api, {
    required String market,
    required String side,
    required String amount,
  }) => api.prepareTrade(
    credentialId: credentialId,
    market: market,
    side: side,
    amount: amount,
  );

  @override
  Future<void> authorize(SokoniApi api, PreparedOp op) async {
    // The biometric prompt. The challenge is the userOpHash, and the account
    // verifies this exact signature on-chain.
    final assertion = await _service.sign(
      challenge: op.challenge,
      allowCredentialIds: [credentialId],
    );
    await api.submit(opId: op.opId, assertion: assertion);
  }
}

PasskeyAuthenticatorService passkeyServiceFor(AppConfig config) =>
    PasskeyAuthenticatorService(
      relyingPartyId: config.relyingPartyId,
      relyingPartyName: 'Sokoni',
      // Passkeys Doctor explains a failed Digital Asset Links check instead
      // of the platform's opaque error — worth the noise only in debug.
      authenticator: PasskeyAuthenticator(debugMode: kDebugMode),
    );

/// Remembers which passkey this device signed up with. The private key is
/// in the platform authenticator and never here — this keeps only the
/// public half and the credential id, which is everything needed to find
/// the account again on a cold start or after logging out. Without it a
/// passkey account would be unreachable the moment the app restarted: the
/// gateway's register call needs the public key, and an assertion alone
/// does not carry one.
class PasskeyCredentialStore {
  PasskeyCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _key = 'sokoni.passkey.credential';

  Future<void> save(RegisteredPasskey passkey) => _storage.write(
    key: _key,
    value: jsonEncode({
      'credentialId': passkey.credentialId,
      'x': passkey.publicKey.xHex,
      'y': passkey.publicKey.yHex,
    }),
  );

  Future<RegisteredPasskey?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return RegisteredPasskey(
        credentialId: j['credentialId'] as String,
        publicKey: PublicKeyCoords(
          BigInt.parse((j['x'] as String).substring(2), radix: 16),
          BigInt.parse((j['y'] as String).substring(2), radix: 16),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}
