import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/theme_mode.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/mera/mera_key_service.dart';
import '../../data/signer.dart';
import '../../data/wallet_connect/wallet_connect_signer.dart';
import '../../design/format.dart';

/// Account identity and device settings. Security used to hardcode
/// "Passkey" here regardless of how the account actually signs — true for
/// the WebAuthn path, wrong for a connected external wallet, which is the
/// only production path today (see welcome_screen.dart). [signer]'s runtime
/// type is the one place that distinction still exists this deep in the
/// tree, so it's threaded through just for this label rather than adding a
/// parallel "how did we sign in" enum.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    required this.config,
    required this.account,
    required this.onLogout,
    this.signer,
    this.onSwitchWallet,
    super.key,
  });

  final AppConfig config;
  final AccountInfo account;

  /// Null for the passkey/WebAuthn path (not a [Signer] — see
  /// AppShell.signer's own doc). [LocalKeySigner] for an on-device Mera key,
  /// [WalletConnectSigner] for an external wallet — each gets its own
  /// Security copy below rather than one label that's only accurate for one
  /// of the three.
  final Signer? signer;
  final Future<void> Function() onLogout;
  final Future<void> Function()? onSwitchWallet;

  bool get _isExternalWallet => signer is WalletConnectSigner;
  bool get _isLocalKey => signer is LocalKeySigner;

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
            _MenuTile(
              icon: Icons.shield_outlined,
              label: 'Security',
              subtitle:
                  _isExternalWallet
                      ? 'External wallet · ${account.deployed ? 'deployed' : 'counterfactual'}'
                      : _isLocalKey
                      ? 'Device key · ${account.deployed ? 'deployed' : 'counterfactual'}'
                      : 'Passkey · ${account.deployed ? 'deployed' : 'counterfactual'}',
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
            if (onSwitchWallet != null)
              _MenuTile(
                icon: Icons.swap_horiz,
                label: 'Switch wallet',
                subtitle: 'Disconnect and connect a different one',
                onTap: onSwitchWallet,
              ),
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

  /// Explains *why* the account is safe, not just what it is — a bare
  /// address dialog answers "what do I have" but not "why should I trust
  /// this", which is the actual question a first-time crypto user has. The
  /// three points differ by [signer] type since the true claim differs: an
  /// external wallet's key isn't on this device at all, so the WebAuthn
  /// copy ("bound to this device's secure hardware") would be a false
  /// promise for the only path production actually offers today.
  void _showSecurityDetails(BuildContext context) {
    final theme = Theme.of(context);
    final (title, points) = switch ((_isExternalWallet, _isLocalKey)) {
      (true, _) => (
        'Your external wallet',
        [
          const _SecurityPoint(
            icon: Icons.smartphone,
            text:
                'Your key lives in your wallet app, not here. Sokoni never '
                'sees it — every trade is signed over WalletConnect and '
                'sent back approved, never handed over.',
          ),
          const _SecurityPoint(
            icon: Icons.key_off,
            text:
                'No shared secret crosses the network. Sokoni only ever '
                'receives a signature, never anything that could be reused '
                'to sign on your behalf.',
          ),
          const _SecurityPoint(
            icon: Icons.local_gas_station_outlined,
            text:
                'Sokoni sponsors gas for you, so this account never needs '
                'to hold MON to trade.',
          ),
        ],
      ),
      (false, true) => (
        'Your device key',
        [
          const _SecurityPoint(
            icon: Icons.smartphone,
            text:
                'Generated and held on this device. There is no seed '
                'phrase to write down, lose, or have phished.',
          ),
          const _SecurityPoint(
            icon: Icons.key_off,
            text:
                'No shared secret. Nothing crosses the network that a copy '
                'could reuse to sign on your behalf.',
          ),
          const _SecurityPoint(
            icon: Icons.local_gas_station_outlined,
            text:
                'Sokoni sponsors gas for you, so this account never needs '
                'to hold MON to trade.',
          ),
        ],
      ),
      (false, false) => (
        'Your passkey',
        [
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
        ],
      ),
    };
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
                  Text(title, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 16),
                  ...points,
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
