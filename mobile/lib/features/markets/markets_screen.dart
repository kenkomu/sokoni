import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../trade/trade_screen.dart';
import 'market_list_controller.dart';

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
      appBar: AppBar(title: const Text('Markets')),
      body: SafeArea(child: _body(state)),
    );
  }

  Widget _body(MarketListState state) {
    if (state.loading && state.markets == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.markets == null) {
      return _ErrorState(message: state.error!, onRetry: _controller.load);
    }
    final markets = state.markets ?? const [];
    if (markets.isEmpty) {
      return const Center(child: Text('No markets are trading yet.'));
    }
    return RefreshIndicator(
      onRefresh: _controller.load,
      child: ListView.separated(
        itemCount: markets.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder:
            (context, i) => _MarketRow(
              market: markets[i],
              onTap:
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder:
                          (_) => TradeScreen(
                            config: widget.config,
                            symbol: markets[i].symbol,
                          ),
                    ),
                  ),
            ),
      ),
    );
  }
}

class _MarketRow extends StatelessWidget {
  const _MarketRow({required this.market, required this.onTap});

  final MarketInfo market;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      title: Text(
        market.symbol,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        'tick ${market.tickSize}  ·  min ${market.minQty}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
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
