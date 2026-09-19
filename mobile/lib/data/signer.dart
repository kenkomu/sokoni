import 'dart:typed_data';

/// Anything that can prove ownership of an Ethereum address by producing an
/// EIP-191 personal-sign signature over a 32-byte hash — the exact shape
/// the gateway's `meraEthSignedHash`/`VerifyMeraSignature` expect (see
/// backend/internal/account/mera.go). [MeraController] talks to this
/// interface only, never a concrete key type, so a connected external
/// wallet (Reown AppKit) is a second implementation of the same contract
/// [LocalKeySigner] already satisfies — not a second prepare/submit code
/// path. `/v1/mera/accounts`, `/v1/mera/ops`, and `/v1/mera/ops/{id}/submit`
/// never learn which kind of signer answered.
abstract class Signer {
  /// The EIP-55 checksummed address this signer signs for — what
  /// `/v1/mera/accounts` registers and every operation is prepared against.
  String get address;

  /// Signs [hash] (always exactly 32 bytes: a userOpHash) and returns the
  /// 65-byte r||s||v signature, v in {27, 28}. May involve a real round
  /// trip to a wallet app (WalletConnect's personal_sign) or be purely
  /// local (an on-device key) — always async so both shapes fit the same
  /// interface, and a caller never has to know which one it got.
  Future<Uint8List> sign(Uint8List hash);
}
