import 'package:flutter/material.dart';

import '../core/config.dart';
import '../data/api/sokoni_api.dart';
import '../data/signer.dart';
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
    this.signer,
    super.key,
  });

  final AppConfig config;
  final AccountInfo account;
  final VoidCallback onLogout;

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

class _AppShellState extends State<AppShell> {
  int _index = 0;

  void _goToMarkets() => setState(() => _index = 2);

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
