import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/demo_mode.dart';
import '../../core/favourites.dart';
import '../../data/repositories/market_summary.dart';
import '../../design/demo_badge.dart';
import '../../design/format.dart';
import '../../design/skeleton.dart';
import '../../design/sparkline.dart';
import '../../design/sparkline_placeholder.dart';
import '../../design/theme.dart';
import '../../design/token_avatar.dart';
import '../trade/trade_screen.dart';
import 'market_list_controller.dart';

enum _TabFilter { all, gainer, loser, favourites }

class MarketsScreen extends StatefulWidget {
  const MarketsScreen({required this.config, super.key});

  final AppConfig config;

  @override
  State<MarketsScreen> createState() => _MarketsScreenState();
}

class _MarketsScreenState extends State<MarketsScreen> {
  late final MarketListController _controller = MarketListController(
    config: widget.config,
  );

  _TabFilter _filter = _TabFilter.all;

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
        child: ValueListenableBuilder<Set<String>>(
          valueListenable: favouriteSymbols,
          builder: (context, favourites, _) => _body(state, favourites),
        ),
      ),
    );
  }

  Widget _body(MarketListState state, Set<String> favourites) {
    if (state.loading && state.summaries == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: SkeletonMarketList(count: 6),
      );
    }
    if (state.error != null && state.summaries == null) {
      return _ErrorState(message: state.error!, onRetry: _controller.load);
    }
    final all = state.summaries ?? const [];
    final filtered = switch (_filter) {
      _TabFilter.all => all,
      _TabFilter.gainer =>
        all.where((s) => (s.changePct?.sign ?? 0) > 0).toList(),
      _TabFilter.loser =>
        all.where((s) => (s.changePct?.sign ?? 0) < 0).toList(),
      _TabFilter.favourites =>
        all.where((s) => favourites.contains(s.market.symbol)).toList(),
    };
    return RefreshIndicator(
      onRefresh: _controller.load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _MarketMoveBanner(summaries: all),
          const SizedBox(height: 20),
          Row(
            children: [
              Text(
                'Coins',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (demoModeEnabled.value) ...[
                const SizedBox(width: 8),
                const DemoBadge(),
              ],
            ],
          ),
          const SizedBox(height: 12),
          _FilterTabs(
            selected: _filter,
            onSelected: (f) => setState(() => _filter = f),
          ),
          const SizedBox(height: 12),
          if (all.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('No markets are trading yet.'),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(_emptyFilterMessage(_filter)),
            )
          else
            for (final s in filtered)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _MarketRow(
                  summary: s,
                  favourite: favourites.contains(s.market.symbol),
                  onToggleFavourite: () => toggleFavourite(s.market.symbol),
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
        ],
      ),
    );
  }

  String _emptyFilterMessage(_TabFilter filter) => switch (filter) {
    _TabFilter.gainer => 'No gainers yet.',
    _TabFilter.loser => 'No losers yet.',
    _TabFilter.favourites => 'No favourites yet — tap the star on a coin.',
    _TabFilter.all => 'No markets are trading yet.',
  };
}

/// The kit's "Market is down -11.17%" header, honestly scoped: it averages
/// each market's own last-candle change (see [MarketSummary.changePct]),
/// never a fabricated 24h figure the gateway doesn't provide.
class _MarketMoveBanner extends StatelessWidget {
  const _MarketMoveBanner({required this.summaries});
  final List<MarketSummary> summaries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sokoni = theme.extension<SokoniColors>()!;
    final changes = [
      for (final s in summaries)
        if (s.changePct != null) s.changePct!,
    ];
    if (changes.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Market data unavailable',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'No trades recorded yet',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    final avg = (changes.reduce((a, b) => a + b) /
            Decimal.fromInt(changes.length))
        .toDecimal(scaleOnInfinitePrecision: 6)
        .round(scale: 2);
    final down = avg.sign < 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
            children: [
              TextSpan(text: 'Market is ${down ? 'down' : 'up'} '),
              TextSpan(
                text: '${down ? '' : '+'}$avg%',
                style: TextStyle(color: down ? sokoni.ask : sokoni.bid),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Since each market’s last trade',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _FilterTabs extends StatelessWidget {
  const _FilterTabs({required this.selected, required this.onSelected});

  final _TabFilter selected;
  final ValueChanged<_TabFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        for (final f in _TabFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: InkWell(
              onTap: () => onSelected(f),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _label(f),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color:
                          f == selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 3,
                    width: 24,
                    color:
                        f == selected
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _label(_TabFilter f) => switch (f) {
    _TabFilter.all => 'All',
    _TabFilter.gainer => 'Gainer',
    _TabFilter.loser => 'Loser',
    _TabFilter.favourites => 'Favourites',
  };
}

class _MarketRow extends StatelessWidget {
  const _MarketRow({
    required this.summary,
    required this.favourite,
    required this.onToggleFavourite,
    required this.onTap,
  });

  final MarketSummary summary;
  final bool favourite;
  final VoidCallback onToggleFavourite;
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
                    Text(
                      market.symbol,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
              SizedBox(
                width: 78,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      candle == null ? '—' : formatPrice(candle.close),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      overflow: TextOverflow.ellipsis,
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
              ),
              IconButton(
                onPressed: onToggleFavourite,
                // 44x44 minimum touch target even though the icon itself is
                // small — the row's density shouldn't shrink what's tappable.
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: Icon(
                  favourite ? Icons.star : Icons.star_border,
                  size: 20,
                  color:
                      favourite
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 32, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
