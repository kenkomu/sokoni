import 'package:flutter/material.dart';

import 'format.dart';

/// Real logos for the handful of tokens that have a universally recognised
/// one (bundled under assets/tokens/, sourced from atomiclabs/cryptocurrency-
/// icons — checked live that each URL actually resolved before downloading,
/// same discipline as everything else in this codebase). MON, AUSD, WMON and
/// XAUt0-USDC's XAUt0 leg have no reliable public icon CDN entry (confirmed
/// 404 on the same source), so they fall through to the coloured-initial
/// avatar below rather than shipping a broken image — this map only ever
/// grows by adding an asset that was actually checked to exist, never by
/// guessing a filename.
const _knownLogos = {'BTC': 'btc', 'ETH': 'eth', 'USDC': 'usdc'};

/// A per-token logo where one exists, a coloured initial otherwise. Sokoni
/// trades a small, evolving set of tokens (see
/// `backend/internal/chain/addresses.go`), so the initial fallback is what
/// makes this scale to any symbol the backend adds without a broken-image
/// icon the day it does.
class TokenAvatar extends StatelessWidget {
  const TokenAvatar({required this.symbol, this.size = 40, super.key});

  final String symbol;
  final double size;

  @override
  Widget build(BuildContext context) {
    final logo = _knownLogos[symbol.toUpperCase()];
    if (logo != null) {
      return ClipOval(
        child: Image.asset(
          'assets/tokens/$logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _initialAvatar(),
        ),
      );
    }
    return _initialAvatar();
  }

  Widget _initialAvatar() {
    final color = colorForSymbol(symbol);
    final initial = symbol.isEmpty ? '?' : symbol[0].toUpperCase();
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color.withValues(alpha: 0.15),
      child: Text(
        initial,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.4,
        ),
      ),
    );
  }
}
