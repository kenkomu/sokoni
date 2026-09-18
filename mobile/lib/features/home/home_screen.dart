import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/demo_mode.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/repositories/market_summary.dart';
import '../../design/demo_badge.dart';
import '../../design/format.dart';
import '../../design/skeleton.dart';
import '../../design/sparkline.dart';
import '../../design/sparkline_placeholder.dart';
import '../../design/theme.dart';
import '../../design/token_avatar.dart';
import '../trade/trade_screen.dart';
import 'home_controller.dart';

/// The first tab after onboarding. A greeting plus the markets a person can
/// trade — the same data the Markets tab shows, at a glance rather than in
/// full, so opening the app answers "what's moving" without a second tap.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.config,
    required this.account,
    required this.onViewMarkets,
    super.key,
  });

  final AppConfig config;
  final AccountInfo account;
  final VoidCallback onViewMarkets;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HomeController _controller = HomeController(config: widget.config);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.load();
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _controller.load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _WelcomeCard(
                account: widget.account,
                onViewMarkets: widget.onViewMarkets,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text(
                    'Markets',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (demoModeEnabled.value) ...[
                    const SizedBox(width: 8),
                    const DemoBadge(),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              ..._marketsBody(state),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _marketsBody(HomeState state) {
    if (state.loading && state.summaries == null) {
      return const [SkeletonMarketList()];
    }
    if (state.error != null && state.summaries == null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            state.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ];
    }
    final summaries = state.summaries ?? const [];
    if (summaries.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('No markets are trading yet.'),
        ),
      ];
    }
    return [
      for (final s in summaries)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _MarketSummaryCard(
            summary: s,
            onTap:
                () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (_) => TradeScreen(
                          config: widget.config,
                          market: s.market,
                        ),
                  ),
                ),
          ),
        ),
    ];
  }
}

class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({required this.account, required this.onViewMarkets});

  final AccountInfo account;
  final VoidCallback onViewMarkets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Welcome back,',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onPrimary.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            shortAddress(account.address),
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onPrimary,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onViewMarkets,
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.onPrimary,
              foregroundColor: theme.colorScheme.primary,
            ),
            child: const Text('View markets'),
          ),
        ],
      ),
    );
  }
}

class _MarketSummaryCard extends StatelessWidget {
  const _MarketSummaryCard({required this.summary, required this.onTap});

  final MarketSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sokoni = theme.extension<SokoniColors>()!;
    final market = summary.market;
    final candle = summary.lastCandle;
    final changePct = summary.changePct;

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              TokenAvatar(symbol: market.baseSymbol),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(market.symbol, style: theme.textTheme.titleMedium),
                    Text(
                      market.baseSymbol,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              summary.sparkline != null
                  ? Sparkline(values: summary.sparkline!, width: 44, height: 22)
                  : const SparklinePlaceholder(width: 44, height: 22),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    candle == null ? '—' : formatPrice(candle.close),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (changePct != null)
                    Text(
                      '${changePct.sign < 0 ? '' : '+'}$changePct%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: changePct.sign < 0 ? sokoni.ask : sokoni.bid,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
