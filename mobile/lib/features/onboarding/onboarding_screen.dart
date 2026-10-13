import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/session_store.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/passkey/passkey_service.dart';
import '../../data/passkey/passkey_signer.dart';
import '../../design/app_shell.dart';
import '../../design/theme.dart';
import 'passkey_controller.dart';
import 'sign_out.dart';

/// Create an account with a fingerprint — no seed phrase appears anywhere,
/// because there isn't one, and the account never holds MON, because the
/// paymaster pays. Presented as a bottom sheet over [WelcomeScreen] rather
/// than a full page: it is one short action, not a multi-step flow, and a
/// sheet lets the person see (and dismiss back to) the welcome screen behind
/// it instead of a route stack getting deeper.
Future<void> showPasskeySheet(BuildContext context, AppConfig config) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _PasskeySheet(config: config),
  );
}

class _PasskeySheet extends StatefulWidget {
  const _PasskeySheet({required this.config});

  final AppConfig config;

  @override
  State<_PasskeySheet> createState() => _PasskeySheetState();
}

class _PasskeySheetState extends State<_PasskeySheet> {
  late final PasskeyController _controller = PasskeyController(
    config: widget.config,
  );

  // The sheet closes itself the instant the account exists — navigation
  // happens from inside the listener, not a button, so nothing has to be
  // tapped twice. Guarded so a rebuild can't re-trigger it.
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // Needs no auth, so this loads immediately.
    _controller.loadConfig();
    _start();
  }

  // Opening this sheet *is* "create a wallet" — the same reasoning as
  // wallet_connect_sheet.dart's single-tap connect: a person who tapped
  // "Create a wallet" on the screen behind this one already decided, and
  // parking on a second "Create passkey" button only makes them confirm
  // their own tap. Availability is still checked first, so an unsupported
  // device says so instead of the biometric prompt failing unexplained.
  Future<void> _start() async {
    await _controller.checkAvailability();
    if (!mounted || _controller.state.available == false) return;
    // A passkey this device already made (then logged out of) signs back
    // into the same account rather than minting a second, empty one.
    final existing = await PasskeyCredentialStore().load();
    if (!mounted) return;
    if (existing != null) {
      await _controller.useExisting(existing);
    } else {
      await _controller.createPasskey();
    }
  }

  void _onChanged() {
    setState(() {});
    final account = _controller.state.account;
    if (account != null && !_navigated) {
      _navigated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _enterApp(account));
    }
  }

  Future<void> _enterApp(AccountInfo account) async {
    final registered = _controller.state.registered;
    if (!mounted || registered == null) return;
    final signer = PasskeySigner(registered, config: widget.config);
    final navigator = Navigator.of(context);
    await PasskeyCredentialStore().save(registered);
    await SessionStore().save(SignedInKind.passkey);
    // Same Navigator both calls: close the sheet, then replace the welcome
    // page underneath it with AppShell, so the back button from AppShell
    // never lands back on either.
    navigator.pop();
    navigator.pushReplacement(
      MaterialPageRoute(
        builder:
            (_) => AppShell(
              config: widget.config,
              account: account,
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
    final registered = state.registered;
    final account = state.account;

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
              'Your account is your fingerprint',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'A key is generated inside this device’s secure hardware. It '
              'never leaves, so there is nothing to write down and nothing '
              'to lose — unlike a seed phrase.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),

            _NetworkBanner(config: widget.config),
            const SizedBox(height: 20),

            if (state.available == false) const _UnsupportedNotice(),

            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.icon(
                onPressed:
                    state.isBusy || state.available == false
                        ? null
                        : _controller.createPasskey,
                icon:
                    state.stage == PasskeyStage.registering
                        ? const _Spinner()
                        : const Icon(Icons.fingerprint),
                label: Text(
                  registered != null
                      ? 'Create another'
                      // Reached only after the automatic attempt in _start
                      // has already failed once — this is now a retry, not
                      // the first ask.
                      : state.error != null
                      ? 'Try again'
                      : 'Create passkey',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),

            if (registered != null) ...[
              const SizedBox(height: 16),
              _KeyCard(registered: registered),
            ],

            // The platform made the key but the gateway never heard about it.
            // Offer the second half again — not a second passkey.
            if (registered != null && account == null && !state.isBusy) ...[
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
    // Mainnet and testnet must never be confusable at a glance — a build
    // pointed at real money should look different from one that isn't.
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
  const _KeyCard({required this.registered});
  final RegisteredPasskey registered;

  @override
  Widget build(BuildContext context) {
    return _Disclosure(
      summary: 'Passkey ready',
      icon: Icons.check_circle_outline,
      child: _DataCard(
        title: 'Account owner',
        subtitle: 'These coordinates are what SokoniAccount stores on-chain.',
        rows: {
          'x': registered.publicKey.xHex,
          'y': registered.publicKey.yHex,
          'credential': registered.credentialId,
        },
      ),
    );
  }
}

/// A card that starts collapsed behind one reassuring line, for detail that
/// proves something to a reviewer but would only alarm a first-time user —
/// raw key material. Tapping it open costs one gesture; leaving it open by
/// default costs a calm first impression.
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
      // ExpansionTile's default divider reads as a stray line above the next
      // card; suppress it rather than accept the mismatch.
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
            // Hex is long; let it wrap rather than clipping, and keep the
            // digits monospaced so they can be compared by eye against a
            // block explorer.
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

class _UnsupportedNotice extends StatelessWidget {
  const _UnsupportedNotice();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 20),
      child: _Notice(
        icon: Icons.phonelink_erase_outlined,
        message:
            'This device does not support passkeys. Android 9 or later '
            'with Google Play services is required.',
      ),
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) =>
      _Notice(icon: Icons.error_outline, message: message);
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});

  final IconData icon;
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
          Icon(icon, size: 18, color: theme.colorScheme.onErrorContainer),
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

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 16,
    height: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
