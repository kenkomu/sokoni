import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/session_store.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/signer.dart';
import '../../design/app_shell.dart';
import '../../design/theme.dart';
import 'mera_controller.dart';
import 'sign_out.dart';

/// Create (or resume) an account with a key held on this device — no
/// biometric prompt, no WebAuthn relying-party domain, no seed phrase.
/// Structurally this is [showPasskeySheet]'s twin: same bottom-sheet
/// presentation over [WelcomeScreen], same "close itself the instant the
/// account exists" navigation. See mera_controller.dart and
/// data/mera/mera_key_service.dart for what's actually different underneath.
Future<void> showMeraSheet(BuildContext context, AppConfig config) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _MeraSheet(config: config),
  );
}

class _MeraSheet extends StatefulWidget {
  const _MeraSheet({required this.config});

  final AppConfig config;

  @override
  State<_MeraSheet> createState() => _MeraSheetState();
}

class _MeraSheetState extends State<_MeraSheet> {
  late final MeraController _controller = MeraController(config: widget.config);

  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.loadConfig();
    // Unlike the passkey sheet, there is nothing to ask the platform first —
    // go straight for the on-device key.
    _controller.loadOrCreateKey();
  }

  void _onChanged() {
    setState(() {});
    final account = _controller.state.account;
    if (account != null && !_navigated) {
      _navigated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _enterApp(account));
    }
  }

  void _enterApp(MeraAccountInfo meraAccount) {
    if (!mounted) return;
    // Recorded so a cold start knows to restore the on-device key rather
    // than showing the welcome screen — see SessionStore's doc.
    SessionStore().save(SignedInKind.localKey);

    final signer = _controller.state.signer;
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.pushReplacement(
      MaterialPageRoute(
        builder:
            (_) => AppShell(
              config: widget.config,
              // AppShell (and every screen under it) only ever reads
              // .address off this — nothing downstream keys off
              // credentialId (see the grep that confirmed this before
              // adding the conversion) — so the owner address stands in for
              // it here rather than threading a second account type through
              // AppShell for a field nothing needs.
              account: AccountInfo(
                credentialId: meraAccount.owner,
                address: meraAccount.address,
                deployed: meraAccount.deployed,
              ),
              signer: signer,
              onLogout:
                  () => signOut(
                    navigator,
                    signer,
                    widget.config,
                    autoOpenConnect: false,
                  ),
              onSwitchWallet:
                  () => signOut(
                    navigator,
                    signer,
                    widget.config,
                    autoOpenConnect: true,
                  ),
            ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _controller.state;
    final signer = state.signer;
    final key = signer is EcdsaSigner ? signer : null;

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
              'Your account lives on this device',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'A key is generated on this device and stored in its secure '
              'keystore. It never leaves, so there is nothing to write down '
              'and nothing to lose — unlike a seed phrase.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),

            _NetworkBanner(config: widget.config),
            const SizedBox(height: 20),

            if (state.isBusy) ...[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  switch (state.stage) {
                    MeraStage.loadingKey => 'Setting up your device key…',
                    MeraStage.registering => 'Finding your account…',
                    MeraStage.sending => 'Sending…',
                    MeraStage.idle => '',
                  },
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],

            if (key != null) ...[
              const SizedBox(height: 16),
              _KeyCard(address: key.address),
            ],

            // The key exists but the gateway never heard about it — retry
            // only the network half.
            if (key != null && state.account == null && !state.isBusy) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _controller.registerAccount,
                icon: const Icon(Icons.refresh),
                label: const Text('Look up my account again'),
              ),
            ],

            if (state.error != null) ...[
              const SizedBox(height: 20),
              _ErrorNotice(message: state.error!),
            ],
          ],
        ),
      ),
    );
  }
}

class _NetworkBanner extends StatelessWidget {
  const _NetworkBanner({required this.config});
  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMain = config.isMainnet;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color:
            isMain
                ? theme.colorScheme.errorContainer
                : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            isMain ? Icons.warning_amber_rounded : Icons.science_outlined,
            size: 18,
            color: isMain ? theme.colorScheme.onErrorContainer : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isMain
                  ? 'Monad mainnet — real funds'
                  : 'Monad testnet — practice funds only',
              style: theme.textTheme.labelLarge?.copyWith(
                color: isMain ? theme.colorScheme.onErrorContainer : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.address});
  final String address;

  @override
  Widget build(BuildContext context) {
    return _Disclosure(
      summary: 'Device key ready',
      icon: Icons.check_circle_outline,
      child: _DataCard(
        title: 'Account owner',
        subtitle:
            'This is the address SimpleAccountFactory derives your smart '
            'account from.',
        rows: {'owner': address},
      ),
    );
  }
}

class _Disclosure extends StatelessWidget {
  const _Disclosure({
    required this.summary,
    required this.icon,
    required this.child,
  });

  final String summary;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        leading: Icon(icon, size: 20, color: theme.colorScheme.primary),
        title: Text(
          summary,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: const Text('Tap to see the proof'),
        children: [child],
      ),
    );
  }
}

class _DataCard extends StatelessWidget {
  const _DataCard({
    required this.title,
    required this.subtitle,
    required this.rows,
  });

  final String title;
  final String subtitle;
  final Map<String, String> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          for (final entry in rows.entries) ...[
            Text(
              entry.key,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SelectableText(
              entry.value,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace', height: 1.4)
                  .merge(tabularFigures),
            ),
            const SizedBox(height: 10),
          ],
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
