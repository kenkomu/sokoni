import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../onboarding/mera_controller.dart';

/// Buy or sell [market] at the current market price — a market order only,
/// no limit orders yet (see CLAUDE.md's Known gaps). Reuses [MeraController]
/// rather than a dedicated order controller: the key it needs is already on
/// this device from onboarding, [MeraController.loadOrCreateKey] retrieves
/// it (never minting a second one, same guarantee onboarding relies on), and
/// [MeraController.sendTrade] is the prepare/sign/submit/watch loop a trade
/// needs, identical in shape to the transfer one — the two only differ in
/// which gateway intent they build.
Future<void> showOrderSheet(
  BuildContext context, {
  required AppConfig config,
  required MarketInfo market,
  required String side,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _OrderSheet(config: config, market: market, side: side),
  );
}

class _OrderSheet extends StatefulWidget {
  const _OrderSheet({
    required this.config,
    required this.market,
    required this.side,
  });

  final AppConfig config;
  final MarketInfo market;
  final String side;

  @override
  State<_OrderSheet> createState() => _OrderSheetState();
}

class _OrderSheetState extends State<_OrderSheet> {
  late final MeraController _controller = MeraController(
    config: widget.config,
  );
  final _amountController = TextEditingController();
  bool _landed = false;

  bool get _isBuy => widget.side == 'buy';

  /// The asset the amount field is denominated in: what's being *spent* —
  /// the quote asset (e.g. USDC) for a buy, the base asset (e.g. ETH) for a
  /// sell. Never the asset being received; that's the whole point of a
  /// market order, its output size isn't chosen up front.
  String get _spendSymbol =>
      _isBuy ? widget.market.symbol.split('-').last : widget.market.baseSymbol;

  int get _spendDecimals =>
      _isBuy ? widget.market.quoteDecimals : widget.market.baseDecimals;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.loadOrCreateKey();
  }

  void _onChanged() {
    setState(() {});
    if (_controller.state.op?.landed == true && !_landed) {
      _landed = true;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = _amountController.text.trim();
    if (amount.isEmpty) return;
    _controller.sendTrade(
      market: widget.market.symbol,
      side: widget.side,
      amountHuman: amount,
      decimals: _spendDecimals,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _controller.state;
    final color = _isBuy ? theme.colorScheme.primary : theme.colorScheme.error;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${_isBuy ? 'Buy' : 'Sell'} ${widget.market.baseSymbol}',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Market order — fills at the current price, no minimum '
              'received guaranteed yet.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            if (_landed) ...[
              _SuccessNotice(status: state.op),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ),
            ] else ...[
              TextField(
                controller: _amountController,
                enabled: !state.isBusy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: '$_spendSymbol to ${_isBuy ? 'spend' : 'sell'}',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: color),
                  onPressed: state.isBusy ? null : _submit,
                  child:
                      state.isBusy
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : Text(_isBuy ? 'Buy' : 'Sell'),
                ),
              ),
              if (state.error != null) ...[
                const SizedBox(height: 16),
                _ErrorNotice(message: state.error!),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _SuccessNotice extends StatelessWidget {
  const _SuccessNotice({required this.status});
  final OpStatus? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle_outline, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Order landed',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (status?.txHash != null) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    status!.txHash!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
