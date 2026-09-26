import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/money.dart';
import '../../data/api/sokoni_api.dart';
import '../../design/format.dart';
import '../../design/skeleton.dart';
import '../../design/token_avatar.dart';
import 'portfolio_controller.dart';
import 'recent_activity.dart';

/// Balances are real now — read live via `GET /v1/accounts/{address}/balances`
/// (`internal/gateway/service.go`'s `Balances`, since there is still no
/// ledger table to read instead: `internal/treasury` is still a `.gitkeep`,
/// see CLAUDE.md's Known gaps). Per-market *positions* still are not —
/// nothing here attributes a balance to a specific trade or market, only to
/// the account as a whole.
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
    // The debug preview account (credentialId 'debug-preview', see
    // welcome_screen.dart) was never registered with the gateway — asking
    // it for balances would just be a confusing 404, so it gets none.
    accountAddress:
        widget.account.credentialId == 'debug-preview'
            ? null
            : widget.account.address,
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
              _AccountCard(
                account: widget.account,
                balances: state.balances,
                prices: state.prices,
              ),
              const SizedBox(height: 24),
              Text(
                'Balances',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              ..._balancesBody(state),
              const SizedBox(height: 20),
              RecentActivity(
                config: widget.config,
                items: state.activity,
                loading: state.activityLoading,
                error: state.activityError,
              ),
              const SizedBox(height: 20),
              _ExploreMarketsCard(onViewMarkets: widget.onViewMarkets),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _balancesBody(PortfolioState state) {
    if (widget.account.credentialId == 'debug-preview') {
      return [
        Text(
          'Debug preview account — never registered, so it has no real '
          'balance to read.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ];
    }
    if (state.loading && state.balances == null) {
      return const [SkeletonMarketList()];
    }
    if (state.error != null && state.balances == null) {
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
    // Only tokens actually held — a wall of "0.00 AUSD / 0.00 USDC" rows
    // says nothing a new account doesn't already know.
    final held =
        (state.balances ?? const [])
            .where(
              (b) =>
                  !Money.fromBaseUnits(
                    BigInt.parse(b.amount),
                    b.token.decimals,
                  ).isZero,
            )
            .toList();
    if (held.isEmpty) {
      return [
        Text(
          'No balance yet — send AUSD or USDC to your account address above '
          'to get started.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ];
    }
    return [
      for (final b in held)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _BalanceTile(balance: b),
        ),
    ];
  }
}

/// Portfolio's one way out to trading.
///
/// This replaces a full copy of the market list that used to sit here. Two
/// things were wrong with it: it rendered as the same stack of tiles as the
/// balances directly above, so "what you can trade" read as "what you hold"
/// at a glance — and the only number it showed per market was tick size,
/// which answers a question nobody has while looking at their portfolio.
/// The Markets tab already does this properly, with live prices.
class _ExploreMarketsCard extends StatelessWidget {
  const _ExploreMarketsCard({required this.onViewMarkets});

  final VoidCallback onViewMarkets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onViewMarkets,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Icons.candlestick_chart,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Explore markets',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Live prices, charts, and buy or sell in a tap.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer
                            .withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.balances,
    required this.prices,
  });

  final AccountInfo account;
  final List<AccountBalance>? balances;
  final Map<String, Decimal>? prices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balances = this.balances;
    final prices = this.prices;
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
          const SizedBox(height: 4),
          // Both must have loaded — a total computed from balances alone
          // (before prices arrive) would flash a wrong, too-low number for
          // the one moment prices is still null, and this is the first
          // thing on the screen a new user's eye lands on.
          if (balances != null && prices != null)
            _TotalValue(balances: balances, prices: prices)
          else
            Text(
              '···',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: theme.colorScheme.onPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          const SizedBox(height: 12),
          // The whole row is the tap target, not just the icon: this is the
          // one screen that tells people to send funds here, so copying the
          // address is the main thing they came to do.
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => copyAddress(context, account.address),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        shortAddress(account.address),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: theme.colorScheme.onPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(
                      Icons.copy_rounded,
                      size: 20,
                      color: theme.colorScheme.onPrimary.withValues(
                        alpha: 0.85,
                      ),
                    ),
                  ],
                ),
              ),
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

/// The one number a trading app's own portfolio screen is expected to lead
/// with — total value across every held token, in USDC. Not shown before
/// this session's redesign: balances existed but nothing summed them, so a
/// new user with five different tokens had to do that arithmetic themselves.
class _TotalValue extends StatelessWidget {
  const _TotalValue({required this.balances, required this.prices});

  final List<AccountBalance> balances;
  final Map<String, Decimal> prices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (total, allPriced) = totalValueUsdc(balances, prices);
    final display = total.round(scale: 2).toString();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '\$$display',
          style: theme.textTheme.headlineMedium?.copyWith(
            color: theme.colorScheme.onPrimary,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (!allPriced) ...[
          const SizedBox(width: 6),
          Text(
            '+ more',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimary.withValues(alpha: 0.75),
            ),
          ),
        ],
      ],
    );
  }
}

class _BalanceTile extends StatelessWidget {
  const _BalanceTile({required this.balance});

  final AccountBalance balance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final money = Money.fromBaseUnits(
      BigInt.parse(balance.amount),
      balance.token.decimals,
    );
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            TokenAvatar(symbol: balance.token.symbol),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                balance.token.symbol,
                style: theme.textTheme.titleMedium,
              ),
            ),
            Text(
              formatAmount(money),
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
