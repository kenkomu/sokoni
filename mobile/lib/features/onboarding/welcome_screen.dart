import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../../design/app_shell.dart';
import '../../design/theme.dart';
import 'onboarding_screen.dart';
import 'wallet_connect_sheet.dart';

/// Not a real account — lets the post-onboarding screens be reviewed on real
/// hardware without going through onboarding first. [kDebugMode]-gated:
/// never reachable in a release build.
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
/// stays unreachable from this screen: `SOKONI_RP_ID` now points at
/// `sokoni.bitshada.com`, which does serve a Digital Asset Links file
/// (`GET /.well-known/assetlinks.json` on the gateway itself), but no
/// physical device has ever completed a passkey ceremony against it —
/// that's what the `[kDebugMode]`-only spike button lower on this screen is
/// for. Swap the primary button to it once that's proven. The `passkeys`
/// plugin this app pins (2.22.3) also exposes no PRF extension to back
/// Mera's real vault scheme — see mera_key_service.dart.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    required this.config,
    this.autoOpenConnect = false,
    super.key,
  });

  final AppConfig config;

  /// True only when this screen is the landing spot right after
  /// [signOut]'s "Switch wallet" path — opens [showWalletConnectSheet]
  /// itself on the first frame, so switching wallets is one tap instead of
  /// "log out, look at the welcome screen, tap connect again".
  final bool autoOpenConnect;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.autoOpenConnect) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => showWalletConnectSheet(context, widget.config),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    // Pinned to the light theme regardless of system brightness: this is a
    // fixed marketing splash matching one specific Figma design, not a
    // themed app screen — following system dark mode here would silently
    // diverge from what was asked for, the same reasoning that keeps the
    // rest of the app on SokoniTheme.light() (see CLAUDE.md's decision on
    // the Figma UI kit only having a light surface).
    final theme = SokoniTheme.light();
    final heroHeight = MediaQuery.of(context).size.height * 0.46;
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
                        'Discover the potential of digital assets',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (kDebugMode) ...[
                        _DebugPreviewCard(config: config),
                        const SizedBox(height: 12),
                      ],
                      _GradientPillButton(
                        label: 'Connect a wallet',
                        onPressed:
                            () => showWalletConnectSheet(context, config),
                      ),
                      const SizedBox(height: 12),
                      if (kDebugMode) ...[
                        // SPIKE, remove once the passkey path has a real
                        // button: proving one real device can complete a
                        // WebAuthn ceremony against a live assetlinks.json
                        // is the one open unknown gating the "Create a
                        // wallet" option — see docs/adr and CLAUDE.md's
                        // Known gaps.
                        _OutlinePillButton(
                          label: 'Create a wallet',
                          onPressed: () => showPasskeySheet(context, config),
                        ),
                        const SizedBox(height: 12),
                      ],
                      const SizedBox(height: 4),
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
                          onLogout: () async => Navigator.pop(context),
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

/// The primary CTA, styled after the "FINANCIAL MONEY APP" Figma community
/// file's Sign In pill: a gradient fill sweeping through the hero's own
/// palette (so the button reads as part of the same system, not a
/// mismatched accent), a stadium shape, and a trailing arrow rather than an
/// icon — the destination (a wallet-connect sheet) isn't a single glyph the
/// way "wallet" was on the old icon button.
class _GradientPillButton extends StatelessWidget {
  const _GradientPillButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(29),
          gradient: const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xFF0063F5), Color(0xFF7C4DFF), Color(0xFF22D3C1)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0063F5).withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(29),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Icon(Icons.arrow_forward, color: Colors.white),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The secondary CTA — same pill shape and arrow as [_GradientPillButton],
/// outlined instead of filled, matching the reference's "Sign Up" pairing.
class _OutlinePillButton extends StatelessWidget {
  const _OutlinePillButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          side: BorderSide(color: theme.colorScheme.primary, width: 1.4),
        ),
        onPressed: onPressed,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_forward, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

/// The gradient graphic at the top — two overlapping colour blobs (the
/// reference's arcs) behind Sokoni's own tokens (MON, AUSD, USDC) rather than
/// the source design's Bitcoin/Ethereum glyphs, since those aren't what this
/// app actually trades, plus a logo mark and headline the source screen
/// carries in its hero rather than the body below it.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(40)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Container(
            // The base the blobs sit on. A flat colour matching Blob B's own
            // darkest stop, not a gradient toward navy — a two-tone base was
            // visible as a hard dark wedge in the bottom-left corner, the one
            // spot neither circle's bleed reliably reaches at every screen
            // height, and a mismatched base colour there read as a bug
            // rather than part of the composition.
            decoration: const BoxDecoration(color: Color(0xFF5A35C4)),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Blob A: teal-cyan, bleeding off the top-right corner —
                // matches the reference's outer arc.
                Positioned(
                  top: -h * 0.35,
                  right: -w * 0.5,
                  child: Container(
                    width: w * 1.5,
                    height: w * 1.5,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF22D3C1), Color(0xFF0063F5)],
                      ),
                    ),
                  ),
                ),
                // Blob B: purple-magenta, sized generously past the hero's
                // own corners (not just enough to reach them) so the base
                // colour above is only ever a hairline fallback, never a
                // visible wedge — the failure mode a smaller circle hit.
                Positioned(
                  top: -h * 0.75,
                  left: -w * 0.7,
                  child: Container(
                    width: w * 1.9,
                    height: w * 1.9,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFB24DFF), Color(0xFF5A35C4)],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.35,
                    child: CustomPaint(painter: _PriceLinePainter()),
                  ),
                ),
                Positioned(
                  left: 24,
                  top: 0,
                  right: 24,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _LogoMark(),
                          const SizedBox(height: 18),
                          Text(
                            'Welcome to\nSokoni',
                            style: Theme.of(
                              context,
                            ).textTheme.headlineMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 20,
                  bottom: 24,
                  child: Row(
                    children: const [
                      _HeroBubble(symbol: 'MON', size: 40),
                      SizedBox(width: 8),
                      _HeroBubble(symbol: 'AUSD', size: 40),
                      SizedBox(width: 8),
                      _HeroBubble(symbol: 'USDC', size: 40),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The reference's white rounded-square logo mark, redrawn as Sokoni's own
/// initial rather than reusing an unrelated brand's glyph.
class _LogoMark extends StatelessWidget {
  const _LogoMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'S',
        style: TextStyle(
          color: Color(0xFF0063F5),
          fontWeight: FontWeight.w800,
          fontSize: 24,
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
