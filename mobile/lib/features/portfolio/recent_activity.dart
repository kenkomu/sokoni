import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/money.dart';
import '../../data/api/sokoni_api.dart';
import '../../design/format.dart';

class RecentActivity extends StatelessWidget {
  const RecentActivity({
    required this.config,
    required this.items,
    required this.loading,
    required this.error,
    super.key,
  });

  final AppConfig config;
  final List<AccountActivity>? items;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent activity',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        if (loading && items == null)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            ),
          )
        else if (error != null && items == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Activity couldn’t load. Pull down to refresh.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          )
        else if ((items ?? const []).isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Your trades and transfers will appear here.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final item in items!)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ActivityTile(item: item, config: config),
            ),
      ],
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.item, required this.config});

  final AccountActivity item;
  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, icon, color) = switch (item.status) {
      'prepared' => (
        'Awaiting approval',
        Icons.hourglass_top,
        theme.colorScheme.tertiary,
      ),
      'submitted' => ('Pending', Icons.sync, theme.colorScheme.primary),
      'landed' => (
        'Successful',
        Icons.check_circle_outline,
        const Color(0xFF17834A),
      ),
      'reverted' ||
      'failed' => ('Failed', Icons.error_outline, theme.colorScheme.error),
      'expired' => (
        'Expired',
        Icons.timer_off_outlined,
        theme.colorScheme.onSurfaceVariant,
      ),
      _ => ('Checking', Icons.help_outline, theme.colorScheme.onSurfaceVariant),
    };
    final amount = formatAmount(
      Money.fromBaseUnits(BigInt.parse(item.amount), item.decimals),
    );
    final title = switch (item.kind) {
      'trade' => '${_capitalise(item.side)} ${item.market}',
      'transfer' => 'Transfer ${item.asset}',
      _ => _capitalise(item.kind),
    };
    // item.asset/amount is always the *base* leg (see the gateway's own
    // ActivityView.QuoteAsset doc) -- which side is "spent" vs "received"
    // still depends on which way the trade went. Only known once a real
    // fill exists (quoteAsset null until then), so a still-pending trade
    // just shows its base leg alone, same as before.
    final quoteAmount = item.quoteAmount;
    final quoteAsset = item.quoteAsset;
    String legLine;
    if (item.kind == 'trade' && quoteAmount != null && quoteAsset != null) {
      final quote = formatAmount(
        Money.fromBaseUnits(BigInt.parse(quoteAmount), item.quoteDecimals ?? 0),
      );
      legLine =
          item.side == 'sell'
              ? '$amount ${item.asset} → $quote $quoteAsset'
              : '$quote $quoteAsset → $amount ${item.asset}';
    } else {
      legLine = item.asset.isEmpty ? '' : '$amount ${item.asset}';
    }
    final subtitle =
        legLine.isEmpty
            ? _when(item.createdAt)
            : '$legLine · ${_when(item.createdAt)}';

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap:
            item.txHash == null ? null : () => _openTransaction(item.txHash!),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (item.status == 'failed' || item.status == 'reverted')
                      if (item.reason != null && item.reason!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          item.reason!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    // The gateway never records *why* a prepared operation
                    // expired (its own reason column is always blank for
                    // this status — it's a Redis TTL lapsing, not a
                    // decodable failure), so this is a fixed explanation
                    // rather than an empty-looking "Expired" chip with
                    // nothing underneath it.
                    if (item.status == 'expired') ...[
                      const SizedBox(height: 4),
                      Text(
                        'The signing window closed before this was '
                        'submitted — no funds moved.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(color: color),
                  ),
                  if (item.txHash != null)
                    Icon(
                      Icons.open_in_new,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openTransaction(String hash) async {
    await launchUrl(
      Uri.parse(explorerTransactionUrl(config.chainId, hash)),
      mode: LaunchMode.externalApplication,
    );
  }
}

String _capitalise(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

String _when(DateTime time) {
  final difference = DateTime.now().difference(time.toLocal());
  if (difference.inSeconds < 60) return 'Just now';
  if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
  if (difference.inHours < 24) return '${difference.inHours}h ago';
  if (difference.inDays < 7) return '${difference.inDays}d ago';
  return '${time.toLocal().year}-${time.toLocal().month.toString().padLeft(2, '0')}-${time.toLocal().day.toString().padLeft(2, '0')}';
}
