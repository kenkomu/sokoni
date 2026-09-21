import 'dart:typed_data';

import 'package:reown_core/reown_core.dart';
import 'package:reown_sign/reown_sign.dart';
import 'package:web3dart/crypto.dart';

import '../signer.dart';

/// A [Signer] backed by a real external wallet (MetaMask, Trust Wallet,
/// Rainbow, ...) connected through raw WalletConnect v2 (`reown_sign`) —
/// [ReownSignClient] owns the actual session; this just adapts it to the one
/// method [MeraController] needs. Signing is a real round trip to the wallet
/// app (a personal_sign prompt the person approves there), unlike
/// [LocalKeySigner], which never leaves the device.
///
/// personal_sign is chain-agnostic — it signs arbitrary bytes with the
/// wallet's existing key, so the connected wallet never needs to recognise
/// Monad as a network at all. Everything chain-specific (building the
/// UserOperation, submitting it, paying gas) happens in the gateway, exactly
/// as it does for [LocalKeySigner] — this signer's only job is producing
/// the same 65-byte r||s||v signature over the same EIP-191-wrapped hash.
class WalletConnectSigner implements Signer {
  WalletConnectSigner(this._client, this._session, {required this.chainId});

  final ReownSignClient _client;
  final SessionData _session;

  /// CAIP-2, e.g. "eip155:143" for Monad mainnet.
  final String chainId;

  @override
  String get address {
    // Namespace accounts are CAIP-10: "eip155:<chainId>:<address>".
    final accounts = _session.namespaces['eip155']?.accounts ?? const [];
    if (accounts.isEmpty) {
      throw StateError('WalletConnectSigner: no eip155 account in session');
    }
    return accounts.first.split(':').last;
  }

  @override
  Future<Uint8List> sign(Uint8List hash) async {
    // Message hex first, address second — the standard personal_sign
    // parameter order (confirmed against Reown's own example app, not
    // guessed: a wrong order here fails the exact same way a MetaMask
    // dapp's would).
    final pending = _client.request(
      topic: _session.topic,
      chainId: chainId,
      request: SessionRequestParams(
        method: 'personal_sign',
        params: [bytesToHex(hash, include0x: true), address],
      ),
    );
    // Deliberately after dispatching and before awaiting: the request has to
    // be on the relay before the wallet is brought forward, or the person
    // arrives to an app with nothing to approve yet. Same ordering
    // reown_appkit uses (appkit_modal_impl.dart's _launchRequestOnWallet).
    await _openWallet();
    return hexToBytes(await pending as String);
  }

  /// Bring the connected wallet forward so the pending prompt is in front of
  /// the person, rather than leaving them to find the app themselves.
  ///
  /// Best-effort on purpose. The wallet may publish no redirect, the scheme
  /// may not resolve, or the session may have been made by scanning a QR
  /// code from another device entirely — none of which is a signing failure,
  /// so a miss here just leaves the request pending and switching apps
  /// manual, exactly as it was before.
  Future<void> _openWallet() async {
    final redirect = _session.peer.metadata.redirect;
    final link = redirect?.native ?? redirect?.universal;
    if (link == null || link.isEmpty) return;
    try {
      await ReownCoreUtils.openURL(link);
    } catch (_) {
      // Swallowed: see above.
    }
  }
}
