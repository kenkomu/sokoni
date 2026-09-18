import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/demo_mode.dart';
import '../data/api/sokoni_api.dart';
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
    super.key,
  });

  final AppConfig config;
  final AccountInfo account;
  final VoidCallback onLogout;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  void _goToMarkets() => setState(() => _index = 2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Keyed by the demo flag: each of these three fetches its data once in
      // initState, so toggling demo mode in Profile needs them rebuilt from
      // scratch to pick up the change, not just repainted.
      body: ValueListenableBuilder<bool>(
        valueListenable: demoModeEnabled,
        builder: (context, demo, _) {
          final tabs = [
            HomeScreen(
              key: ValueKey('home-$demo'),
              config: widget.config,
              account: widget.account,
              onViewMarkets: _goToMarkets,
            ),
            PortfolioScreen(
              key: ValueKey('portfolio-$demo'),
              config: widget.config,
              account: widget.account,
              onViewMarkets: _goToMarkets,
            ),
            MarketsScreen(
              key: ValueKey('markets-$demo'),
              config: widget.config,
            ),
            ProfileScreen(
              config: widget.config,
              account: widget.account,
              onLogout: widget.onLogout,
            ),
          ];
          return IndexedStack(index: _index, children: tabs);
        },
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
