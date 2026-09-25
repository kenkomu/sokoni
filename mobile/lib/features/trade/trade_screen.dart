import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
// Prefixed: intl exports its own TextDirection, which shadows dart:ui's.
import 'package:intl/intl.dart' as intl;
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/favourites.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/signer.dart';
import '../../design/format.dart';
import '../../design/price_flash.dart';
import '../../design/theme.dart';
import '../../design/token_avatar.dart';
import 'candle_chart.dart';
import 'order_sheet.dart';
import 'trade_controller.dart';

/// The kit's "Coin page" — price, chart, recent trades, and what market
/// metadata actually exists (tick size, min qty, contracts), plus Buy/Sell,
/// which place a real sponsored market order via [showOrderSheet].
class TradeScreen extends StatefulWidget {
  const TradeScreen({
    required this.config,
    required this.market,
    this.signer,
    super.key,
  });

  final AppConfig config;
  final MarketInfo market;

  /// See AppShell.signer. Null (passkey or debug-preview accounts) disables
  /// Buy/Sell rather than trading with an unrelated key — see
  /// order_sheet.dart.
  final Signer? signer;

  @override
  State<TradeScreen> createState() => _TradeScreenState();
}

/// One entry per tab: the candle bucket size Kuru's own candlestick API
/// documents (docs.kuru.io/api-reference/market-data/get-candlestick-data:
/// 1m/5m/15m/30m/1h/4h/1d/1w) paired with how many of that size buckets add
/// up to the label's time range, e.g. 6H = 72 five-minute candles. A single
/// interval stretched across every tab (the original behaviour) meant "24H"
/// was 1,440 one-minute bars crammed into one chart — unreadable, and not
/// actually how Kuru's own candlestick views work.
///
/// 1W and 30D reuse the 3600s/86400s buckets 24H and the old "All" already
/// read (gateway.candleIntervalsS only populates 60/300/3600/86400s — Kuru's
/// own 1w bucket isn't one of them, and adding it would mean a bucket with no
/// history until a week after it started being populated). A week of hourly
/// candles (168) and a month of daily ones (30) both fit gateway's
/// per-request cap of 500 with room to spare.
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
  _TimeRange('1W', 3600, 168), // 168 x 1h
  _TimeRange('30D', 86400, 30), // 30 x 1d
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
    _controller.load24hStats();
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
                    _PriceHeader(
                      candles: state.candles,
                      trades: state.trades,
                      stats24h: state.stats24h,
                      baseSymbol: market.baseSymbol,
                    ),
                    const SizedBox(height: 12),
                    _TimeRangeChips(
                      selectedIntervalS: state.candleInterval,
                      selectedLimit: state.candleLimit,
                      onSelected:
                          (range) => _controller.loadInitial(
                            interval: range.intervalS,
                            limit: range.limit,
                          ),
                    ),
                    const SizedBox(height: 12),
                    CandleChart(candles: state.candles ?? const []),
                    const SizedBox(height: 20),
                    _MarketDetailsPanel(
                      trades: state.trades,
                      market: market,
                      config: widget.config,
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
      ),
      bottomNavigationBar: _BuySellBar(
        config: widget.config,
        market: market,
        signer: widget.signer,
      ),
    );
  }
}

class _TimeRangeChips extends StatelessWidget {
  const _TimeRangeChips({
    required this.selectedIntervalS,
    required this.selectedLimit,
    required this.onSelected,
  });

  /// Both fields are needed to identify the selected tab: 24H and 1W now
  /// share the same [_TimeRange.intervalS] (3600s, see [_windows]) and are
  /// told apart only by how many buckets each asks for.
  final int selectedIntervalS;
  final int selectedLimit;
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
                selected:
                    selectedIntervalS == range.intervalS &&
                    selectedLimit == range.limit,
                onSelected: (_) => onSelected(range),
                labelStyle: theme.textTheme.labelMedium?.copyWith(
                  color:
                      selectedIntervalS == range.intervalS &&
                              selectedLimit == range.limit
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
  const _PriceHeader({
    required this.candles,
    required this.trades,
    required this.stats24h,
    required this.baseSymbol,
  });

  final List<Candle>? candles;
  final List<MarketTrade>? trades;
  final Market24hStats? stats24h;
  final String baseSymbol;

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
            if (stats24h != null &&
                (stats24h!.high != null ||
                    stats24h!.low != null ||
                    stats24h!.volume != null)) ...[
              const SizedBox(height: 4),
              _Stats24hRow(stats: stats24h!, baseSymbol: baseSymbol),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stats24hRow extends StatelessWidget {
  const _Stats24hRow({required this.stats, required this.baseSymbol});

  final Market24hStats stats;
  final String baseSymbol;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget stat(String label, String? value, {String suffix = ''}) {
      if (value == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(right: 14),
        child: RichText(
          text: TextSpan(
            style: style,
            children: [
              TextSpan(text: '$label '),
              TextSpan(
                text: '${formatPrice(value)}$suffix',
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Wrap(
      children: [
        stat('24h H', stats.high),
        stat('24h L', stats.low),
        stat('24h Vol', stats.volume, suffix: ' $baseSymbol'),
      ],
    );
  }
}

/// Recent trades and market info both used to sit permanently on the
/// scroll — most of a screen's height spent on data most people check only
/// occasionally, pushing the chart (what people actually look at first)
/// further from the top. Collapsed by default behind one disclosure, with
/// an internal Trades/Info switch instead of stacking both, so opening it
/// costs one tap and one glance, not a long scroll.
class _MarketDetailsPanel extends StatefulWidget {
  const _MarketDetailsPanel({
    required this.trades,
    required this.market,
    required this.config,
  });

  final List<MarketTrade>? trades;
  final MarketInfo market;
  final AppConfig config;

  @override
  State<_MarketDetailsPanel> createState() => _MarketDetailsPanelState();
}

class _MarketDetailsPanelState extends State<_MarketDetailsPanel> {
  bool _expanded = false;
  bool _showTrades = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Trades & market info',
                    style: theme.textTheme.titleSmall,
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child:
              _expanded
                  ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _buildExpanded(theme),
                  )
                  : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _buildExpanded(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _SegmentButton(
                  label: 'Trades',
                  selected: _showTrades,
                  onTap: () => setState(() => _showTrades = true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SegmentButton(
                  label: 'Market info',
                  selected: !_showTrades,
                  onTap: () => setState(() => _showTrades = false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_showTrades)
            _TradesTable(trades: widget.trades)
          else
            _MarketStats(market: widget.market, config: widget.config),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color:
          selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
              : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  selected
                      ? Colors.transparent
                      : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              color:
                  selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _TradesTable extends StatelessWidget {
  const _TradesTable({required this.trades});

  final List<MarketTrade>? trades;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = trades ?? const [];
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No trades yet.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Price', style: labelStyle)),
            Expanded(
              child: Text(
                'Amount',
                textAlign: TextAlign.right,
                style: labelStyle,
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                'Time',
                textAlign: TextAlign.right,
                style: labelStyle,
              ),
            ),
          ],
        ),
        const Divider(height: 14),
        for (final t in rows) _TradeRow(trade: t),
      ],
    );
  }
}

/// What actually helps someone verify what they're trading: the two
/// contract addresses, each with a copy button and a link out to Monad's
/// own block explorer for independent verification (see explorerTokenUrl's
/// doc — the whole point of showing an address here). Tick size and min
/// quantity used to sit here too, but no CEX or DEX headlines exchange
/// mechanics like that on a coin page — they only matter in the moment of
/// placing an order, so they moved to order_sheet.dart instead. There is
/// also no market cap, 24h volume or supply row: no data source for those
/// beyond the 24h high/low/volume already shown by [_PriceHeader], which
/// the gateway's own candles cover.
class _MarketStats extends StatelessWidget {
  const _MarketStats({required this.market, required this.config});
  final MarketInfo market;
  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ContractRow(
          label: 'Base contract',
          address: market.baseToken,
          chainId: config.chainId,
        ),
        _ContractRow(
          label: 'Quote contract',
          address: market.quoteToken,
          chainId: config.chainId,
        ),
      ],
    );
  }
}

class _ContractRow extends StatelessWidget {
  const _ContractRow({
    required this.label,
    required this.address,
    required this.chainId,
  });

  final String label;
  final String address;
  final int chainId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.token_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
            shortAddress(address),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 16),
            visualDensity: VisualDensity.compact,
            tooltip: 'Copy address',
            onPressed: () => copyAddress(context, address),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 16),
            visualDensity: VisualDensity.compact,
            tooltip: 'View on explorer',
            onPressed:
                () => launchUrl(
                  Uri.parse(explorerTokenUrl(chainId, address)),
                  mode: LaunchMode.externalApplication,
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
  const _BuySellBar({required this.config, required this.market, this.signer});

  final AppConfig config;
  final MarketInfo market;
  final Signer? signer;

  @override
  Widget build(BuildContext context) {
    final s = signer;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s == null)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Trading isn\'t available for this account yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed:
                        s == null
                            ? null
                            : () => showOrderSheet(
                              context,
                              config: config,
                              market: market,
                              side: 'buy',
                              signer: s,
                            ),
                    child: const Text('Buy'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed:
                        s == null
                            ? null
                            : () => showOrderSheet(
                              context,
                              config: config,
                              market: market,
                              side: 'sell',
                              signer: s,
                            ),
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
          SizedBox(
            width: 64,
            child: Text(
              trade.blockTime == null
                  ? '—'
                  : intl.DateFormat(
                    'HH:mm:ss',
                  ).format(trade.blockTime!.toLocal()),
              textAlign: TextAlign.right,
              style: tabularFigures.merge(
                theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
