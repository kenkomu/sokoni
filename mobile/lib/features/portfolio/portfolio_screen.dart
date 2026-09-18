import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/repositories/market_summary.dart';
import '../../design/format.dart';
import '../../design/skeleton.dart';
import '../../design/token_avatar.dart';
import 'portfolio_controller.dart';

/// Balances and positions per account are not implemented yet — there is no
/// endpoint (`internal/treasury` is still a `.gitkeep`, see CLAUDE.md's
/// Known gaps). Rather than show a fabricated number, this screen states
/// that plainly and shows what is real today: the account itself, and which
/// markets are available to trade.
class PortfolioScreen extends StatefulWidget {
  const PortfolioScreen({
    required this.config,
    required this.account,
    required this.onViewMarkets,
    super.key,
  });

  final AppConfig config;
  final AccountInfo account;
  final VoidCallback onViewMarkets;

  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  late final PortfolioController _controller = PortfolioController(
    config: widget.config,
  );

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
      appBar: AppBar(title: const Text('Portfolio')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _controller.load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _AccountCard(account: widget.account),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Available markets',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onViewMarkets,
                    child: const Text('Trade'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Positions aren’t tracked yet — this lists what you can '
                'trade, not what you hold.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              ..._marketsBody(state),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _marketsBody(PortfolioState state) {
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
    return [
      for (final s in summaries)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _MarketTile(summary: s),
        ),
    ];
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account});

  final AccountInfo account;

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
            'Your account',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            shortAddress(account.address),
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            account.deployed
                ? 'Live on-chain — Sokoni covers the gas, so it never needs '
                    'to hold MON.'
                : 'Ready to receive funds now. Your first transfer creates '
                    'it on-chain.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimary.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

class _MarketTile extends StatelessWidget {
  const _MarketTile({required this.summary});

  final MarketSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            TokenAvatar(symbol: summary.market.baseSymbol),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.market.symbol,
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    'tick ${summary.market.tickSize}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
