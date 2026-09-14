import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/passkey/passkey_service.dart';
import '../../design/theme.dart';
import 'passkey_controller.dart';

/// Proves the Phase 1 thesis on a real device: create an account with a
/// fingerprint, then move a token with it. No seed phrase appears anywhere,
/// because there isn't one, and the account never holds MON, because the
/// paymaster pays.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({required this.config, super.key});

  final AppConfig config;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final PasskeyController _controller = PasskeyController(
    config: widget.config,
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // Ask up front, so an unsupported device says so before the user commits
    // to a flow that cannot finish.
    _controller.checkAvailability();
    // Needs no auth, so this loads immediately — the amount field can show
    // a real token symbol from the first frame, not a bare number.
    _controller.loadConfig();
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _recipient.dispose();
    _amount.dispose();
    super.dispose();
  }

  // Prefilled so the demo is one tap. The dead address is a conventional
  // sink: whatever lands there is visibly gone, which is the point.
  final _recipient = TextEditingController(
    text: '0x000000000000000000000000000000000000dEaD',
  );
  final _amount = TextEditingController(text: '1');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _controller.state;
    final registered = state.registered;
    final account = state.account;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
          children: [
            Text(
              'Sokoni',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Your account is your fingerprint.',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),

            _NetworkBanner(config: widget.config),
            const SizedBox(height: 20),

            if (state.available == false) const _UnsupportedNotice(),

            _Step(
              index: 1,
              title: 'Create a passkey',
              body:
                  'A key is generated inside this device’s secure hardware. '
                  'It never leaves, so there is nothing to write down and '
                  'nothing to lose — unlike a seed phrase.',
              done: registered != null,
              action: FilledButton.icon(
                onPressed:
                    state.isBusy || state.available == false
                        ? null
                        : _controller.createPasskey,
                icon:
                    state.stage == PasskeyStage.registering
                        ? const _Spinner()
                        : const Icon(Icons.fingerprint),
                label: Text(
                  registered == null ? 'Create passkey' : 'Create another',
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

            if (account != null) ...[
              const SizedBox(height: 16),
              _AccountCard(account: account),
            ],

            const SizedBox(height: 24),

            _Step(
              index: 2,
              title: 'Move a token with it',
              body:
                  'Your fingerprint authorises it — no password, no seed '
                  'phrase. The gateway covers the network fee, so the '
                  'account never needs to hold any MON of its own.',
              done: state.op?.landed ?? false,
              action: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _recipient,
                    enabled: account != null && !state.isBusy,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: tabularFigures,
                    decoration: const InputDecoration(
                      labelText: 'Recipient',
                      hintText: '0x…',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _amount,
                    enabled: account != null && !state.isBusy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: tabularFigures,
                    decoration: InputDecoration(
                      labelText: 'Amount',
                      suffixText: state.token?.symbol,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed:
                        state.isBusy || account == null
                            ? null
                            : () => _controller.send(
                              to: _recipient.text.trim(),
                              amount: _amount.text.trim(),
                            ),
                    icon:
                        state.stage == PasskeyStage.sending
                            ? const _Spinner()
                            : const Icon(Icons.send_outlined),
                    label: const Text('Sign and send'),
                  ),
                ],
              ),
            ),

            if (state.op != null) ...[
              const SizedBox(height: 16),
              _OpCard(op: state.op!),
            ],

            if (state.lastAssertion != null) ...[
              const SizedBox(height: 16),
              _AssertionCard(assertion: state.lastAssertion!),
            ],

            if (state.error != null) ...[
              const SizedBox(height: 24),
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

class _Step extends StatelessWidget {
  const _Step({
    required this.index,
    required this.title,
    required this.body,
    required this.action,
    required this.done,
  });

  final int index;
  final String title;
  final String body;
  final Widget action;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color:
                done
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
          ),
          child:
              done
                  ? Icon(
                    Icons.check,
                    size: 16,
                    color: theme.colorScheme.onPrimary,
                  )
                  : Text('$index', style: theme.textTheme.labelMedium),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              action,
            ],
          ),
        ),
      ],
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

class _AssertionCard extends StatelessWidget {
  const _AssertionCard({required this.assertion});
  final PasskeyAssertion assertion;

  @override
  Widget build(BuildContext context) {
    return _Disclosure(
      summary: 'Signed',
      icon: Icons.check_circle_outline,
      child: _DataCard(
        title: 'Signature',
        subtitle:
            's is normalised to the low half — Monad’s precompile accepts '
            'both forms, so the account rejects the malleable one.',
        rows: {
          'r': assertion.signature.rHex,
          's': assertion.signature.sHex,
          'challenge offset': '${assertion.challengeIndex}',
        },
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account});
  final AccountInfo account;

  @override
  Widget build(BuildContext context) {
    return _DataCard(
      title: 'Your account',
      subtitle:
          account.deployed
              ? 'Live on-chain. It never needs MON — Sokoni covers the fee.'
              : 'This address is ready to receive funds now, even though '
                  'nothing is on-chain yet. Your first transfer creates it.',
      rows: {'address': account.address},
    );
  }
}

class _OpCard extends StatelessWidget {
  const _OpCard({required this.op});
  final OpStatus op;

  @override
  Widget build(BuildContext context) {
    return _DataCard(
      title: switch (op.status) {
        'landed' => 'Landed on-chain',
        'reverted' => 'Reached the chain, but reverted',
        'submitted' => 'Submitted — waiting for a block',
        'expired' => 'Expired before it was signed',
        _ => 'Prepared',
      },
      subtitle:
          op.landed
              ? 'Gas was paid by the Sokoni paymaster, not by you.'
              : 'The Sokoni paymaster pays the gas.',
      rows: {
        if (op.userOpHash != null) 'userOpHash': op.userOpHash!,
        if (op.txHash != null) 'transaction': op.txHash!,
        if (op.blockNumber != null) 'block': '${op.blockNumber}',
        if (op.reason != null) 'reason': op.reason!,
      },
    );
  }
}

/// A card that starts collapsed behind one reassuring line, for detail that
/// proves something to a reviewer but would only alarm a first-time user —
/// raw key material, a signature's r/s. Tapping it open costs one gesture;
/// leaving it open by default costs a calm first impression.
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
