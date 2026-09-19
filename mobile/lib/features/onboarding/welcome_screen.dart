import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../../design/app_shell.dart';
import '../../design/theme.dart';
import 'onboarding_screen.dart';
import 'wallet_connect_sheet.dart';

/// Not a real account — `sokoni.app` has no Digital Asset Links entry for any
/// device yet (see CLAUDE.md), so no phone can complete passkey registration
/// today. This lets the post-onboarding screens be reviewed on real hardware
/// before that's set up. [kDebugMode]-gated: never reachable in a release
/// build.
const _previewAccount = AccountInfo(
  credentialId: 'debug-preview',
  address: '0x000000000000000000000000000000000000dEaD',
  deployed: false,
);

/// The app's first screen — copy and layout match Screen 1 of the "Crypto
/// Trading App Design" Figma community file. One entry point: connecting an
/// external wallet ([showWalletConnectSheet]), which signs through the same
/// [MeraController]/gateway flow the on-device Mera key used
/// ([WalletConnectSigner] vs. [LocalKeySigner] — see data/signer.dart).
/// [showPasskeySheet]'s WebAuthn path is still wired up and tested, but
/// stays unreachable from this screen: it needs `sokoni.app` (or whatever
/// `SOKONI_RP_ID` names) to serve a Digital Asset Links file for this
/// build's signing certificate, which nobody has stood up yet, and the
/// `passkeys` plugin this app pins (2.22.3) exposes no PRF extension to
/// back Mera's real vault scheme either — see mera_key_service.dart.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({required this.config, super.key});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    // Pinned to the light theme regardless of system brightness: this is a
    // fixed marketing splash matching one specific Figma design, not a
    // themed app screen — following system dark mode here would silently
    // diverge from what was asked for, the same reasoning that keeps the
    // rest of the app on SokoniTheme.light() (see CLAUDE.md's decision on
    // the Figma UI kit only having a light surface).
    final theme = SokoniTheme.light();
    final heroHeight = MediaQuery.of(context).size.height * 0.42;
    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        // Fixed-height hero, then a scrolling body below it — safer than
        // Expanded+spaceBetween, which overflows the instant its content
        // (e.g. the debug preview card) is taller than the leftover space.
        body: Column(
          children: [
            SizedBox(height: heroHeight, child: const _Hero()),
            Expanded(
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Empower Your Financial Future with Crypto Trading',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Discover the potential of digital assets. Trade, '
                        'invest, and grow with confidence.',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (kDebugMode) ...[
                        _DebugPreviewCard(config: config),
                        const SizedBox(height: 16),
                      ],
                      SizedBox(
                        width: double.infinity,
                        height: 58,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            shape: const StadiumBorder(),
                          ),
                          onPressed:
                              () => showWalletConnectSheet(context, config),
                          icon: const Icon(
                            Icons.account_balance_wallet_outlined,
                          ),
                          label: const Text(
                            'Connect a wallet',
                            style: TextStyle(fontSize: 18),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock_outline,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Your keys stay in your wallet app',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      const _WalletSupportRow(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Debug-only escape hatch into [AppShell] with a fake account, so the
/// screens behind onboarding can be reviewed without a working passkey —
/// see [_previewAccount] for why that step doesn't work on a device yet.
class _DebugPreviewCard extends StatelessWidget {
  const _DebugPreviewCard({required this.config});
  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.visibility_outlined,
            size: 18,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Debug build only — skips the passkey step with a fake '
              'account, purely to eyeball the screens.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed:
                () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (_) => AppShell(
                          config: config,
                          account: _previewAccount,
                          onLogout: () => Navigator.pop(context),
                        ),
                  ),
                ),
            child: const Text('Preview'),
          ),
        ],
      ),
    );
  }
}

/// Fills the space the removed "Sign In" / "Create an account" buttons left
/// behind with something that earns its keep: recognisable wallet names so
/// "Connect a wallet" reads as a real, well-supported option rather than a
/// dead end, since [showWalletConnectSheet] works with any WalletConnect v2
/// wallet, not just these four — see wallet_connect_signer.dart.
class _WalletSupportRow extends StatelessWidget {
  const _WalletSupportRow();

  static const _wallets = [
    (letter: 'M', name: 'MetaMask', color: Color(0xFFF6851B)),
    (letter: 'T', name: 'Trust Wallet', color: Color(0xFF3375BB)),
    (letter: 'R', name: 'Rainbow', color: Color(0xFF001E59)),
    (letter: 'C', name: 'Coinbase', color: Color(0xFF0052FF)),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Works with your favorite wallet',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final wallet in _wallets) ...[
              _WalletChip(letter: wallet.letter, color: wallet.color),
              const SizedBox(width: 10),
            ],
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              child: Text(
                '+300',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _WalletChip extends StatelessWidget {
  const _WalletChip({required this.letter, required this.color});

  final String letter;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        letter,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 16,
        ),
      ),
    );
  }
}

/// The gradient graphic at the top — a price-line motif over Sokoni's own
/// tokens (MON, AUSD, USDC) rather than the source design's Bitcoin/Ethereum
/// glyphs, since those aren't what this app actually trades.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(40)),
      child: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.3, -0.4),
            radius: 1.3,
            colors: [
              theme.colorScheme.primary,
              const Color(0xFF0A1A5C),
              const Color(0xFF060B1F),
            ],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _PriceLinePainter())),
            const Positioned(
              left: 28,
              top: 60,
              child: _HeroBubble(symbol: 'AUSD', size: 64),
            ),
            const Positioned(
              right: 40,
              top: 24,
              child: _HeroBubble(symbol: 'MON', size: 72),
            ),
            const Positioned(
              right: 24,
              bottom: 28,
              child: _HeroBubble(symbol: 'USDC', size: 64),
            ),
          ],
        ),
      ),
    );
  }
}

class _PriceLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = Colors.white.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round;

    // Fixed zigzag, proportional to the box — a decorative motif, not real
    // data, so it never needs to match an actual price.
    const points = [
      Offset(0.00, 0.62),
      Offset(0.12, 0.35),
      Offset(0.24, 0.72),
      Offset(0.38, 0.18),
      Offset(0.50, 0.55),
      Offset(0.64, 0.30),
      Offset(0.78, 0.68),
      Offset(0.90, 0.40),
      Offset(1.00, 0.58),
    ];
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = Offset(points[i].dx * size.width, points[i].dy * size.height);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PriceLinePainter oldDelegate) => false;
}

/// A "frosted glass" token bubble, unlike [TokenAvatar]'s light-card version
/// — a pale tint sits well on Home/Markets' white cards but would nearly
/// vanish on this hero's dark gradient, so this uses a translucent white
/// disc with a bold white glyph instead.
class _HeroBubble extends StatelessWidget {
  const _HeroBubble({required this.symbol, required this.size});

  final String symbol;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
      ),
      alignment: Alignment.center,
      child: Text(
        symbol[0],
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.4,
        ),
      ),
    );
  }
}
