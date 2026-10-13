import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/session_store.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/mera/mera_key_service.dart';
import '../../data/signer.dart';
import '../../data/wallet_connect/wallet_connect_service.dart';
import '../../data/wallet_connect/wallet_connect_signer.dart';
import '../../design/app_shell.dart';
import 'mera_controller.dart';
import 'sign_out.dart';
import 'welcome_screen.dart';

/// The app's actual first screen — decides, once, whether there's a session
/// worth restoring before ever showing [WelcomeScreen]. Without this, every
/// cold start re-ran the full sign-in flow regardless of whether the person
/// connected 30 seconds ago; [SessionStore] only records *which* restore
/// path to attempt, so this is also where "the marker says X but X no
/// longer checks out" gets handled — by falling back to [WelcomeScreen],
/// same as if nothing had ever been signed in.
class StartupGate extends StatefulWidget {
  const StartupGate({required this.config, super.key});

  final AppConfig config;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final kind = await SessionStore().load();
    switch (kind) {
      case null:
        break;
      case SignedInKind.localKey:
        await _restoreLocalKey();
        return;
      case SignedInKind.walletConnect:
        await _restoreWalletConnect();
        return;
    }
    _goWelcome();
  }

  Future<void> _restoreLocalKey() async {
    final key = await MeraKeyService().existing();
    if (key == null) {
      // The marker outlived the key it pointed at (e.g. app storage was
      // cleared partially) — nothing to restore, and leaving the marker
      // behind would just retry this same dead end every launch.
      await SessionStore().clear();
      _goWelcome();
      return;
    }
    await _registerAndEnter(LocalKeySigner(key, keyService: MeraKeyService()));
  }

  Future<void> _restoreWalletConnect() async {
    if (widget.config.walletConnectProjectId.isEmpty) {
      _goWelcome();
      return;
    }
    try {
      // Without a bound, a slow or unreachable relay left the launch spinner
      // up forever with no way out but clearing app data.
      final client = await WalletConnectService.createClient(
        widget.config,
      ).timeout(const Duration(seconds: 8));
      final session = WalletConnectService.findExisting(client, widget.config);
      if (session == null) {
        // Expired or revoked from the wallet's side since last launch.
        await SessionStore().clear();
        _goWelcome();
        return;
      }
      await _registerAndEnter(
        WalletConnectSigner(
          client,
          session,
          chainId: 'eip155:${widget.config.chainId}',
        ),
      );
    } catch (_) {
      // Relay unreachable, or anything else — the welcome screen's own
      // "Connect a wallet" retries this from a clean state either way.
      _goWelcome();
    }
  }

  Future<void> _registerAndEnter(Signer signer) async {
    final controller = MeraController(config: widget.config);
    await controller.useWallet(signer);
    final account = controller.state.account;
    if (!mounted) return;
    if (account == null) {
      // The gateway rejected or couldn't reach re-registration — the
      // marker isn't necessarily wrong (a network blip isn't "logged
      // out"), so it's left alone; the welcome screen's normal connect
      // flow retries the same signer's registration on the next attempt.
      _goWelcome();
      return;
    }
    _goApp(
      AccountInfo(
        credentialId: account.owner,
        address: account.address,
        deployed: account.deployed,
      ),
      signer,
    );
  }

  void _goWelcome() {
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => _welcome()));
  }

  void _goApp(AccountInfo account, Signer signer) {
    final navigator = Navigator.of(context);
    navigator.pushReplacement(
      MaterialPageRoute(
        builder:
            (_) => AppShell(
              config: widget.config,
              account: account,
              signer: signer,
              onLogout:
                  () => signOut(
                    navigator,
                    signer,
                    widget.config,
                    autoOpenConnect: false,
                  ),
              onSwitchWallet:
                  () => signOut(
                    navigator,
                    signer,
                    widget.config,
                    autoOpenConnect: true,
                  ),
            ),
      ),
    );
  }

  WelcomeScreen _welcome() => WelcomeScreen(config: widget.config);

  @override
  Widget build(BuildContext context) {
    // Checking a persisted key and/or reconnecting to the relay is fast in
    // the common case, but never instant — a blank frame here would look
    // like the app hung on launch.
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
