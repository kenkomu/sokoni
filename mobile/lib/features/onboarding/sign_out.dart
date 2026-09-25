import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/session_store.dart';
import '../../data/signer.dart';
import '../../data/wallet_connect/wallet_connect_signer.dart';
import 'welcome_screen.dart';

/// Shared by every "Log out" and "Switch wallet" action, whichever
/// onboarding path signed the person in: both actually end the current
/// session (a WalletConnect signer's session is disconnected on the relay,
/// not just dropped locally — see WalletConnectSigner.disconnect's doc) and
/// forget the app-startup restore marker, so a stale session can never be
/// silently reused after either. The only difference between the two is
/// whether the welcome screen this lands on immediately reopens the connect
/// sheet — see WelcomeScreen.autoOpenConnect.
Future<void> signOut(
  NavigatorState navigator,
  Signer? signer,
  AppConfig config, {
  required bool autoOpenConnect,
}) async {
  if (signer is WalletConnectSigner) {
    await signer.disconnect();
  }
  await SessionStore().clear();
  navigator.pushAndRemoveUntil(
    MaterialPageRoute(
      builder:
          (_) =>
              WelcomeScreen(config: config, autoOpenConnect: autoOpenConnect),
    ),
    (route) => false,
  );
}
