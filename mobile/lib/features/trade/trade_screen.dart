import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../../design/theme.dart';
import 'candle_chart.dart';
import 'trade_controller.dart';

class TradeScreen extends StatefulWidget {
  const TradeScreen({required this.config, required this.symbol, super.key});

  final AppConfig config;
  final String symbol;

  @override
  State<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends State<TradeScreen> {
  late final TradeController _controller = TradeController(
    config: widget.config,
    symbol: widget.symbol,
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.symbol),
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
                    CandleChart(candles: state.candles ?? const []),
                    const SizedBox(height: 24),
                    Text(
                      'Recent trades',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final t in state.trades ?? const [])
                      _TradeRow(trade: t),
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
              trade.px,
              style: tabularFigures.merge(
                theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ),
          Expanded(
            child: Text(
              trade.qty,
              textAlign: TextAlign.right,
              style: tabularFigures.merge(theme.textTheme.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }
}
