import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/demo_mode.dart';
import '../../core/theme_mode.dart';
import '../../data/api/sokoni_api.dart';
import '../../design/format.dart';

/// Account identity and device settings. No password, no seed phrase — the
/// only credential on this screen is the passkey itself, so "Security" shows
/// what the passkey is bound to rather than a change-password flow.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    required this.config,
    required this.account,
    required this.onLogout,
    super.key,
  });

  final AppConfig config;
  final AccountInfo account;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: theme.colorScheme.onPrimary.withValues(
                      alpha: 0.15,
                    ),
                    child: Icon(
                      Icons.fingerprint,
                      size: 36,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    shortAddress(account.address),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onPrimary,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    config.isMainnet ? 'Monad mainnet' : 'Monad testnet',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimary.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _AppearanceTile(),
            const Divider(),
            if (kDebugMode) ...[
              ValueListenableBuilder<bool>(
                valueListenable: demoModeEnabled,
                builder:
                    (context, enabled, _) => SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.auto_graph_outlined),
                      title: const Text('Demo data'),
                      subtitle: const Text(
                        'Debug build only — shows sample charts/prices '
                        'instead of the (currently empty) real markets.',
                      ),
                      value: enabled,
                      onChanged: (v) => demoModeEnabled.value = v,
                    ),
              ),
              const Divider(),
            ],
            _MenuTile(
              icon: Icons.shield_outlined,
              label: 'Security',
              subtitle:
                  'Passkey · ${account.deployed ? 'deployed' : 'counterfactual'}',
              onTap: () => _showSecurityDetails(context),
            ),
            _MenuTile(
              icon: Icons.dns_outlined,
              label: 'Network',
              subtitle: '${config.relyingPartyId} · chain ${config.chainId}',
              onTap: () => _showNetworkDetails(context),
            ),
            _MenuTile(
              icon: Icons.help_outline,
              label: 'Help and Support',
              onTap: null,
            ),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            _MenuTile(
              icon: Icons.logout,
              label: 'Log out',
              destructive: true,
              onTap: onLogout,
            ),
          ],
        ),
      ),
    );
  }

  /// Explains *why* a passkey is safer, not just that it is — a bare address
  /// dialog answers "what do I have" but not "why should I trust this",
  /// which is the actual question a first-time crypto user has.
  void _showSecurityDetails(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder:
          (_) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your passkey', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 16),
                  const _SecurityPoint(
                    icon: Icons.memory,
                    text:
                        'Bound to this device’s secure hardware. It never '
                        'leaves, so there’s nothing to leak or phish — unlike '
                        'a password or seed phrase.',
                  ),
                  const _SecurityPoint(
                    icon: Icons.key_off,
                    text:
                        'No shared secret. A password proves you know '
                        'something; a passkey proves you hold something — '
                        'nothing crosses the network that a copy could reuse.',
                  ),
                  _SecurityPoint(
                    icon: Icons.domain_verification,
                    text:
                        'Scoped to ${config.relyingPartyId} by the platform '
                        'itself. A lookalike site cannot ask your device to '
                        'sign for it, even if it fools you visually.',
                  ),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Account address',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => copyAddress(context, account.address),
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: const Text('Copy'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                  // Stays selectable as well as copyable: on a screen whose
                  // job is showing what the account *is*, being able to grab
                  // half an address to compare against a block explorer is
                  // worth keeping alongside the one-tap copy.
                  SelectableText(
                    account.address,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  void _showNetworkDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Network'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Relying party: ${config.relyingPartyId}'),
                Text('Chain ID: ${config.chainId}'),
                Text('Gateway: ${config.apiBaseUrl}'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }
}

class _AppearanceTile extends StatelessWidget {
  const _AppearanceTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder:
          (context, mode, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.contrast, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 16),
                Expanded(
                  child: Text('Appearance', style: theme.textTheme.bodyLarge),
                ),
                SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_outlined, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_outlined, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.smartphone, size: 18),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) => appThemeMode.value = s.first,
                ),
              ],
            ),
          ),
    );
  }
}

class _SecurityPoint extends StatelessWidget {
  const _SecurityPoint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.label,
    this.subtitle,
    this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = destructive ? theme.colorScheme.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
