import 'package:flutter/material.dart';

import '../core/config.dart';
import '../data/api/sokoni_api.dart';
import '../data/signer.dart';
import '../data/wallet_connect/wallet_connect_signer.dart';
import '../features/home/home_screen.dart';
import '../features/markets/markets_screen.dart';
import '../features/portfolio/portfolio_screen.dart';
import '../features/settings/profile_screen.dart';

/// The four tabs a signed-in person lives in: Home, Portfolio, Markets,
/// Profile. Matches the bottom navigation in the Figma UI kit this was
/// built from, minus its Rewards tab — there is no rewards system here.
class AppShell extends StatefulWidget {
  const AppShell({
    required this.config,
    required this.account,
    required this.onLogout,
    this.onSwitchWallet,
    this.signer,
    super.key,
  });

  final AppConfig config;
  final AccountInfo account;

  /// Async because it may need to end a real WalletConnect session on the
  /// relay before it's safe to navigate away — see sign_out.dart.
  final Future<void> Function() onLogout;

  /// Same as [onLogout] but reopens the connect sheet immediately instead of
  /// stopping at the welcome screen — one tap to sign into a different
  /// wallet instead of two. Null wherever there's nothing meaningful to
  /// switch to (the passkey and debug-preview paths).
  final Future<void> Function()? onSwitchWallet;

  /// The signer that got this account into the app — an on-device key or a
  /// connected wallet — threaded down to every screen with a Buy/Sell button
  /// so a trade signs with the *same* key the account's balance belongs to.
  /// Null for the passkey path (WebAuthn isn't a [Signer]; trading for a
  /// passkey-owned account isn't wired up yet — see CLAUDE.md's Known gaps)
  /// and the debug preview account, both of which show account data but
  /// were never really signed into.
  final Signer? signer;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;

  void _goToMarkets() => setState(() => _index = 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // See WalletConnectSigner.ensureRelayConnected's doc: without this, the
  // sign-request flow itself (open the wallet app, which backgrounds
  // Sokoni) is what causes the relay Android then suspends, and a trade
  // signed anywhere past the initial connect sheet had nothing left to
  // reconnect it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final signer = widget.signer;
    if (signer is WalletConnectSigner) {
      signer.ensureRelayConnected();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(
            config: widget.config,
            account: widget.account,
            signer: widget.signer,
            onViewMarkets: _goToMarkets,
          ),
          PortfolioScreen(
            config: widget.config,
            account: widget.account,
            onViewMarkets: _goToMarkets,
          ),
          MarketsScreen(config: widget.config, signer: widget.signer),
          ProfileScreen(
            config: widget.config,
            account: widget.account,
            onLogout: widget.onLogout,
            onSwitchWallet: widget.onSwitchWallet,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.pie_chart_outline),
            selectedIcon: Icon(Icons.pie_chart),
            label: 'Portfolio',
          ),
          NavigationDestination(
            icon: Icon(Icons.candlestick_chart_outlined),
            selectedIcon: Icon(Icons.candlestick_chart),
            label: 'Markets',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
