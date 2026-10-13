import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Which [Signer] backed the last successful sign-in — enough for the app
/// to know, on a cold start, which restore path to attempt. Not the signer
/// itself: a local key restores from [MeraKeyService]'s own storage, and a
/// WalletConnect session restores from `reown_sign`'s own storage (both
/// already persist themselves) — this only remembers *which one to ask*.
enum SignedInKind {
  localKey,
  walletConnect,
  passkey;

  static SignedInKind? fromName(String? name) => switch (name) {
    'localKey' => localKey,
    'walletConnect' => walletConnect,
    'passkey' => passkey,
    _ => null,
  };
}

/// Whether *some* account was signed into last, so app startup can skip
/// [WelcomeScreen] instead of showing it on every cold start regardless of
/// whether a session is actually still good. [SignedInKind] alone answers
/// "which restore path" — actually restoring (and finding out the session
/// or key no longer checks out) is the caller's job; this store only ever
/// says what was last true, not what's true now.
class SessionStore {
  SessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kindKey = 'sokoni.session.kind';

  Future<void> save(SignedInKind kind) =>
      _storage.write(key: _kindKey, value: kind.name);

  Future<SignedInKind?> load() async =>
      SignedInKind.fromName(await _storage.read(key: _kindKey));

  Future<void> clear() => _storage.delete(key: _kindKey);
}
