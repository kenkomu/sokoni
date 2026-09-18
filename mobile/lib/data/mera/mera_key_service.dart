import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web3dart/crypto.dart';
import 'package:web3dart/web3dart.dart';

/// The Option 2 / Mera path: an owner key for a `SimpleAccount`, held on this
/// device, instead of a WebAuthn/P-256 credential owning a `SokoniAccount`.
///
/// Mera's own scheme derives the *encryption* key for this vault from a
/// WebAuthn PRF extension output (HKDF-SHA256 -> AES-256-GCM), so the
/// plaintext key never touches disk even inside this app's own storage. That
/// requires two things this build does not have: PRF support in the
/// `passkeys` plugin (checked — v2.22.3 exposes no PRF extension at all, see
/// CLAUDE.md's passkey findings for the WebAuthn calls it does expose), and a
/// relying-party domain that actually serves Digital Asset Links for this
/// app's signing certificate (the same `sokoni.app` blocker the original
/// passkey flow has been stuck on).
///
/// So this is a deliberate, documented substitution: the key is generated
/// with a CSPRNG on-device and held in [FlutterSecureStorage], which is
/// itself backed by the Android Keystore / iOS Keychain — hardware-backed
/// on most devices, encrypted at rest, and never synced off-device. It gets
/// the same headline property Mera promises (no seed phrase, nothing for a
/// person to write down or leak by typing it somewhere) without depending on
/// either blocker. [MeraVault.version] is `'device-keystore-v1'` specifically
/// so a future PRF-backed vault can be told apart from this one and migrated,
/// rather than silently reinterpreted.
class MeraKeyService {
  MeraKeyService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _keyStorageKey = 'sokoni.mera.owner_private_key';

  /// Returns the existing owner key if one was already generated on this
  /// device, or null if none exists yet.
  Future<EthPrivateKey?> existing() async {
    final hex = await _storage.read(key: _keyStorageKey);
    if (hex == null) return null;
    return EthPrivateKey.fromHex(hex);
  }

  /// Generates a fresh owner key and persists it, replacing any prior one.
  /// Call [existing] first — this is for "create account", not "sign in
  /// again with what's already here".
  Future<EthPrivateKey> generate() async {
    final rng = Random.secure();
    final key = EthPrivateKey.createRandom(rng);
    await _storage.write(
      key: _keyStorageKey,
      value: bytesToHex(key.privateKey, include0x: true),
    );
    return key;
  }

  /// The address this key owns — what `/v1/mera/accounts` registers and what
  /// signs every subsequent operation.
  String addressOf(EthPrivateKey key) => key.address.hexEip55;

  /// Signs [userOpHash] exactly as the gateway's `meraEthSignedHash` and
  /// `SimpleAccount._validateSignature` expect: EIP-191 personal-sign over
  /// the 32-byte hash, i.e. `keccak256("\x19Ethereum Signed
  /// Message:\n32" || userOpHash)`, then a 65-byte r||s||v signature with v
  /// in {27, 28}. web3dart's [signPersonalMessageToUint8List] applies that
  /// exact prefix by the message's byte length, so no ABI or hashing code
  /// belongs in this app at all — see CLAUDE.md: "the phone does not
  /// ABI-encode."
  Uint8List sign(EthPrivateKey key, Uint8List userOpHash) {
    return key.signPersonalMessageToUint8List(userOpHash);
  }

  /// Irreversibly forgets the on-device key. Used only for a deliberate
  /// "start over" — there is no recovery path once this runs, by design:
  /// there is no seed phrase to fall back to either.
  Future<void> forget() => _storage.delete(key: _keyStorageKey);
}
