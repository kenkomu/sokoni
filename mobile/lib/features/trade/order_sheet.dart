import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/money.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/signer.dart';
import '../../design/format.dart';
import '../onboarding/mera_controller.dart';

/// Buy or sell [market] at the current market price — a market order only,
/// no limit orders yet (see CLAUDE.md's Known gaps). Reuses [MeraController]
/// rather than a dedicated order controller: [MeraController.sendTrade] is
/// the prepare/sign/submit/watch loop a trade needs, identical in shape to
/// the transfer one — the two only differ in which gateway intent they
/// build. [signer] is the one already established at sign-in (an on-device
/// key or a connected wallet) — passed in rather than reloaded, so a trade
/// always signs with the same key the account's balance actually belongs
/// to; a fresh [MeraController.loadOrCreateKey] here would happily mint or
/// load an unrelated on-device key with no funds of its own.
Future<void> showOrderSheet(
  BuildContext context, {
  required AppConfig config,
  required MarketInfo market,
  required String side,
  required Signer signer,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder:
        (_) => _OrderSheet(
          config: config,
          market: market,
          side: side,
          signer: signer,
        ),
  );
}

class _OrderSheet extends StatefulWidget {
  const _OrderSheet({
    required this.config,
    required this.market,
    required this.side,
    required this.signer,
  });

  final AppConfig config;
  final MarketInfo market;
  final String side;
  final Signer signer;

  @override
  State<_OrderSheet> createState() => _OrderSheetState();
}

class _OrderSheetState extends State<_OrderSheet> {
  late final MeraController _controller = MeraController(config: widget.config);
  late final SokoniApi _api = SokoniApi(baseUrl: widget.config.apiBaseUrl);
  final _amountController = TextEditingController();
  bool _landed = false;

  // Null until the balance fetch (which needs the smart account address,
  // learned only once _controller.useWallet's registration resolves)
  // completes. Distinct from "0" — see _balanceLabel.
  String? _availableBalance;
  bool _fetchedBalance = false;

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
    // The already-established signer, not a freshly loaded/minted on-device
    // key — see this file's top doc comment for why that distinction is the
    // whole point.
    _controller.useWallet(widget.signer);
  }

  void _onChanged() {
    setState(() {});
    if (_controller.state.op?.landed == true && !_landed) {
      _landed = true;
    }
    final address = _controller.state.account?.address;
    if (address != null && !_fetchedBalance) {
      _fetchedBalance = true;
      _loadBalance(address);
    }
  }

  /// Knowing what's actually available — not just the market's abstract
  /// tick/min-size rules — is the other half of "can I place this order":
  /// rules say what the book will accept, balance says what you actually
  /// have to offer it. Best-effort: a failed fetch just leaves the balance
  /// line blank rather than blocking the sheet over a read that isn't on
  /// the critical path to placing the trade itself.
  Future<void> _loadBalance(String address) async {
    try {
      final balances = await _api.balances(address);
      for (final b in balances.balances) {
        if (b.token.symbol == _spendSymbol) {
          if (mounted) setState(() => _availableBalance = b.amount);
          return;
        }
      }
      if (mounted) setState(() => _availableBalance = '0');
    } catch (_) {
      // See doc above.
    }
  }

  void _useMax() {
    final available = _availableBalance;
    if (available == null) return;
    _amountController.text =
        Money.fromBaseUnits(BigInt.parse(available), _spendDecimals).toString();
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
    // Closes the keyboard as soon as it stops being needed, well ahead of
    // the pop this eventually leads to — see build()'s PopScope comment for
    // why that gap matters.
    FocusManager.instance.primaryFocus?.unfocus();
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

    // Every way out of this sheet — the Done button, dragging it down,
    // tapping the scrim, the system back gesture — has to close the amount
    // field's keyboard *before* the route actually pops. Skipping that step
    // is what produced a real, reproduced bug on a real device: on Android
    // 15+ (edge-to-edge is mandatory there, no opt-out) plus
    // windowSoftInputMode="adjustResize", popping a route while a TextField
    // is still focused races the IME-close animation against the window
    // resize. Lose that race and the window can get stuck permanently
    // shrunk to roughly the keyboard-open height — every screen after that,
    // for the rest of the app session, renders squeezed into a sliver at
    // the top with the remainder blank, and nothing short of a device
    // reboot clears it. canPop starts false specifically so unfocus() is
    // guaranteed to run and settle before the pop begins, not race it.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        FocusManager.instance.primaryFocus?.unfocus();
        Navigator.of(context).pop(result);
      },
      child: Padding(
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
                if (_availableBalance != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Available: '
                        '${formatAmount(Money.fromBaseUnits(BigInt.parse(_availableBalance!), _spendDecimals))} '
                        '$_spendSymbol',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (_availableBalance != '0' && !state.isBusy)
                        GestureDetector(
                          onTap: _useMax,
                          child: Text(
                            'Max',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
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
                const SizedBox(height: 6),
                // Min size/tick are in the base asset regardless of side —
                // on a Buy the field above is quote-denominated, so this
                // reads as market context ("what this book will accept"),
                // not a literal bound on the number just typed. Only shown
                // here, not as a headline market-info stat: this is the one
                // moment it's actually decision-relevant.
                Text(
                  'Orders fill in ${widget.market.baseSymbol} — min size '
                  '${formatPrice(widget.market.minQty)} · tick '
                  '${formatPrice(widget.market.tickSize)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
                if (state.isBusy) ...[
                  const SizedBox(height: 8),
                  Text(
                    _busyLabel(state),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (state.error != null) ...[
                  const SizedBox(height: 16),
                  _ErrorNotice(message: state.error!),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Distinguishes the two very different waits a submit can be stuck in —
/// without this, a fast wallet approval followed by normal chain
/// confirmation time reads as one long undifferentiated hang, since both
/// look identical as a bare spinner. [MeraState.op] already carries the
/// distinction (prepared/submitted/landed); this just says it out loud.
String _busyLabel(MeraState state) => switch (state.op?.status) {
  null || 'prepared' => 'Waiting for your signature...',
  'submitted' => 'Submitted — confirming on-chain...',
  _ => 'Working...',
};

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
