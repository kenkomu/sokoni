import 'package:reown_core/reown_core.dart';
import 'package:reown_sign/reown_sign.dart';

import '../../core/config.dart';

/// The one place the WalletConnect namespace Sokoni asks for is spelled out
/// — [showWalletConnectSheet] and the app-startup restore path both need to
/// match on it exactly, or a session paired by one would look incompatible
/// to the other.
class WalletConnectService {
  const WalletConnectService._();

  static Future<ReownSignClient> createClient(AppConfig config) =>
      ReownSignClient.createInstance(
        projectId: config.walletConnectProjectId,
        metadata: PairingMetadata(
          name: 'Sokoni',
          description:
              'Trade on Monad with your fingerprint. Balances in AUSD.',
          // Shown to the wallet as this dapp's identity — not a domain we
          // own, so it stays pointed at the one that actually is.
          url: 'https://sokoni.bitshada.com',
          icons: const [],
          redirect: const Redirect(native: 'sokoni://'),
        ),
      );

  static Map<String, RequiredNamespace> namespaces(AppConfig config) => {
    'eip155': RequiredNamespace(
      chains: ['eip155:${config.chainId}'],
      // personal_sign is all WalletConnectSigner needs — see
      // wallet_connect_signer.dart.
      methods: const ['personal_sign'],
      events: const ['chainChanged', 'accountsChanged'],
    ),
  };

  /// An already-paired session covering the exact namespace Sokoni needs,
  /// if the wallet hasn't revoked or let it expire — checked here, not left
  /// to [ReownSignClient.find], because `find` matches on namespace
  /// compatibility only and does not itself look at `expiry`.
  static SessionData? findExisting(ReownSignClient client, AppConfig config) {
    final session = client.find(requiredNamespaces: namespaces(config));
    if (session == null) return null;
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      session.expiry * 1000,
    );
    return expiresAt.isAfter(DateTime.now()) ? session : null;
  }

  /// Ends the session on the relay (so the wallet app sees the disconnect
  /// too, not just Sokoni forgetting about it locally) — without this, a
  /// "logged out" session stays valid and [findExisting] would silently
  /// reconnect to the same wallet on the next "Connect a wallet" tap.
  static Future<void> disconnect(ReownSignClient client, SessionData session) =>
      client.disconnect(
        topic: session.topic,
        reason: const ReownSignError(code: 6000, message: 'User disconnected.'),
      );
}
