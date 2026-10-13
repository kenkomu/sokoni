import 'dart:typed_data';

import 'api/sokoni_api.dart';

/// Whatever authorises operations for one account. [MeraController] and
/// everything above it talk only to this, so which kind of key backs an
/// account is invisible past sign-in: an on-device key or a connected
/// wallet ([EcdsaSigner], via `/v1/mera/*`), or a passkey (PasskeySigner,
/// via `/v1/ops` with a WebAuthn assertion). The gateway builds the same
/// operation either way — only how it is registered and signed differs.
abstract class Signer {
  /// Learns (registering on first call) the smart account this signer
  /// controls. Idempotent on the gateway for both kinds.
  Future<MeraAccountInfo> register(SokoniApi api);

  Future<PreparedOp> prepareTransfer(
    SokoniApi api, {
    required String token,
    required String to,
    required String amount,
  });

  Future<PreparedOp> prepareTrade(
    SokoniApi api, {
    required String market,
    required String side,
    required String amount,
  });

  /// Signs [op]'s challenge (its userOpHash) and hands the result to the
  /// gateway, which verifies it before the bundler ever sees it.
  Future<void> authorize(SokoniApi api, PreparedOp op);
}

/// An owner that proves itself with an EIP-191 personal-sign signature over
/// a 32-byte hash — the exact shape the gateway's `VerifyMeraSignature`
/// expects (backend/internal/account/mera.go). An on-device key and a
/// connected external wallet both are; only [sign] differs between them.
abstract class EcdsaSigner implements Signer {
  /// The EIP-55 checksummed owner address `/v1/mera/*` is keyed by.
  String get address;

  /// Signs [hash] (always exactly 32 bytes: a userOpHash) and returns the
  /// 65-byte r||s||v signature, v in {27, 28}. May be a round trip to a
  /// wallet app or purely local — always async so both fit.
  Future<Uint8List> sign(Uint8List hash);

  @override
  Future<MeraAccountInfo> register(SokoniApi api) =>
      api.registerMeraAccount(owner: address);

  @override
  Future<PreparedOp> prepareTransfer(
    SokoniApi api, {
    required String token,
    required String to,
    required String amount,
  }) => api.prepareMeraTransfer(
    owner: address,
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
  }) => api.prepareMeraTrade(
    owner: address,
    market: market,
    side: side,
    amount: amount,
  );

  @override
  Future<void> authorize(SokoniApi api, PreparedOp op) async {
    final signature = await sign(op.challenge);
    await api.submitMera(opId: op.opId, owner: address, signature: signature);
  }
}
