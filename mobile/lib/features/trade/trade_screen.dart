import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/demo_mode.dart';
import '../../core/favourites.dart';
import '../../data/api/sokoni_api.dart';
import '../../design/demo_badge.dart';
import '../../design/format.dart';
import '../../design/price_flash.dart';
import '../../design/theme.dart';
import '../../design/token_avatar.dart';
import 'candle_chart.dart';
import 'trade_controller.dart';

/// The kit's "Coin page" — price, chart, recent trades, and what market
/// metadata actually exists (tick size, min qty, contracts). Buy/Sell are
/// visible to match the kit's layout but disabled: there is no order
/// placement endpoint yet (see CLAUDE.md's Known gaps, `internal/orders`).
class TradeScreen extends StatefulWidget {
  const TradeScreen({required this.config, required this.market, super.key});

  final AppConfig config;
  final MarketInfo market;

  @override
  State<TradeScreen> createState() => _TradeScreenState();
}

/// One entry per tab: the candle bucket size Kuru's own candlestick API
/// documents (docs.kuru.io/api-reference/market-data/get-candlestick-data:
/// 1m/5m/15m/30m/1h/4h/1d/1w — gateway.candleIntervalsS populates the four
/// used here) paired with how many of that size buckets add up to the
/// label's time range, e.g. 6H = 72 five-minute candles. A single interval
/// stretched across every tab (the previous behaviour) meant "24H" was
/// 1,440 one-minute bars crammed into one chart — unreadable, and not
/// actually how Kuru's own candlestick views work.
class _TimeRange {
  const _TimeRange(this.label, this.intervalS, this.limit);
  final String label;
  final int intervalS;
  final int limit;
}

const _windows = <_TimeRange>[
  _TimeRange('1H', 60, 60), // 60 x 1m
  _TimeRange('6H', 300, 72), // 72 x 5m
  _TimeRange('24H', 3600, 24), // 24 x 1h
  _TimeRange('All', 86400, 90), // 90 x 1d
];

class _TradeScreenState extends State<TradeScreen> {
  late final TradeController _controller = TradeController(
    config: widget.config,
    symbol: widget.market.symbol,
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.loadInitial().then((_) => _controller.subscribeLive());
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
    final market = widget.market;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TokenAvatar(symbol: market.baseSymbol, size: 28),
            const SizedBox(width: 10),
            Text(market.symbol),
          ],
        ),
        actions: [
          ValueListenableBuilder<Set<String>>(
            valueListenable: favouriteSymbols,
            builder: (context, favourites, _) {
              final favourite = favourites.contains(market.symbol);
              return IconButton(
                onPressed: () => toggleFavourite(market.symbol),
                icon: Icon(favourite ? Icons.star : Icons.star_border),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: _StatusBar(status: state.streamStatus),
        ),
      ),
      body: SafeArea(
        child:
            state.loading && state.candles == null
                ? const Center(child: CircularProgressIndicator())
                : state.error != null && state.candles == null
                ? Center(child: Text(state.error!))
                : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (demoModeEnabled.value) ...[
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: DemoBadge(),
                      ),
                      const SizedBox(height: 8),
                    ],
                    _PriceHeader(candles: state.candles, trades: state.trades),
                    const SizedBox(height: 12),
                    _TimeRangeChips(
                      selected: state.candleInterval,
                      onSelected:
                          (range) => _controller.loadInitial(
                            interval: range.intervalS,
                            limit: range.limit,
                          ),
                    ),
                    const SizedBox(height: 12),
                    CandleChart(candles: state.candles ?? const []),
                    const SizedBox(height: 24),
                    Text(
                      'Recent trades',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if ((state.trades ?? const []).isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No trades yet.',
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      for (final t in state.trades!) _TradeRow(trade: t),
                    const SizedBox(height: 24),
                    _MarketStats(market: market),
                    const SizedBox(height: 12),
                  ],
                ),
      ),
      bottomNavigationBar: const _BuySellBar(),
    );
  }
}

class _TimeRangeChips extends StatelessWidget {
  const _TimeRangeChips({required this.selected, required this.onSelected});

  /// The currently-shown interval, in seconds — matches exactly one
  /// [_TimeRange.intervalS] in [_windows].
  final int selected;
  final ValueChanged<_TimeRange> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final range in _windows)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(range.label),
                selected: selected == range.intervalS,
                onSelected: (_) => onSelected(range),
                labelStyle: theme.textTheme.labelMedium?.copyWith(
                  color:
                      selected == range.intervalS
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                ),
                backgroundColor: theme.colorScheme.surface,
                selectedColor: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.4,
                ),
                side: BorderSide(color: theme.colorScheme.outline),
              ),
            ),
        ],
      ),
    );
  }
}

/// The last traded price at a glance, pulsing green/up or red/down on each
/// live tick — see [PriceFlash]. Falls back from the latest candle's close
/// to the latest trade's price, and to an honest "—" if neither exists yet.
class _PriceHeader extends StatelessWidget {
  const _PriceHeader({required this.candles, required this.trades});

  final List<Candle>? candles;
  final List<MarketTrade>? trades;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sokoni = theme.extension<SokoniColors>()!;

    final latest =
        (candles != null && candles!.isNotEmpty)
            ? candles!.last.close
            : (trades != null && trades!.isNotEmpty ? trades!.first.px : null);
    if (latest == null) {
      return Text('—', style: theme.textTheme.headlineMedium);
    }

    final price = Decimal.parse(latest);
    Decimal? changePct;
    if (candles != null && candles!.isNotEmpty) {
      final open = Decimal.parse(candles!.first.open);
      if (open != Decimal.zero) {
        final ratio = (price - open) / open;
        changePct = (ratio.toDecimal(scaleOnInfinitePrecision: 6) *
                Decimal.fromInt(100))
            .round(scale: 2);
      }
    }

    return PriceFlash(
      price: price,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              formatPrice(latest),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (changePct != null) ...[
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${changePct.sign < 0 ? '' : '+'}$changePct%',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: changePct.sign < 0 ? sokoni.ask : sokoni.bid,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What the gateway actually exposes about this market — no market cap,
/// volume or supply, because there is no data source for those (the kit's
/// "Market Stats" assumes a price-feed provider Sokoni doesn't have).
class _MarketStats extends StatelessWidget {
  const _MarketStats({required this.market});
  final MarketInfo market;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Market info', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _StatRow(
          icon: Icons.straighten,
          label: 'Tick size',
          value: market.tickSize,
        ),
        _StatRow(
          icon: Icons.production_quantity_limits,
          label: 'Min quantity',
          value: market.minQty,
        ),
        _StatRow(
          icon: Icons.token_outlined,
          label: 'Base contract',
          value: shortAddress(market.baseToken),
        ),
        _StatRow(
          icon: Icons.token_outlined,
          label: 'Quote contract',
          value: shortAddress(market.quoteToken),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Matches the kit's sticky Buy/Sell bar in position and shape, disabled
/// with an explanation rather than either hidden (which would silently
/// diverge from the design) or wired to an endpoint that doesn't exist.
class _BuySellBar extends StatelessWidget {
  const _BuySellBar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Order placement isn’t live yet',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: null,
                    child: const Text('Buy'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: null,
                    child: const Text('Sell'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.status});

  final StreamStatus status;

  @override
  Widget build(BuildContext context) {
    if (status == StreamStatus.live) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final (label, color) = switch (status) {
      StreamStatus.connecting => (
        'Connecting…',
        theme.colorScheme.onSurfaceVariant,
      ),
      StreamStatus.gap => ('Reconnecting…', theme.colorScheme.error),
      StreamStatus.disconnected => ('Disconnected', theme.colorScheme.error),
      StreamStatus.live => ('', theme.colorScheme.onSurfaceVariant),
    };
    return Container(
      height: 24,
      alignment: Alignment.center,
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _TradeRow extends StatelessWidget {
  const _TradeRow({required this.trade});

  final MarketTrade trade;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<SokoniColors>();
    final color = trade.side == 'buy' ? colors?.bid : colors?.ask;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              formatPrice(trade.px),
              style: tabularFigures.merge(
                theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ),
          Expanded(
            child: Text(
              formatPrice(trade.qty),
              textAlign: TextAlign.right,
              style: tabularFigures.merge(theme.textTheme.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }
}
