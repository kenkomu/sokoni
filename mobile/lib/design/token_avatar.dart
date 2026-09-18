import 'package:flutter/material.dart';

import 'format.dart';

/// A coloured initial in place of a per-token logo asset. Sokoni trades a
/// small, known set of tokens (AUSD, MON, WMON, USDC — see
/// `backend/internal/chain/addresses.go`), so a fetched icon set would be
/// mostly unused weight; this scales to any symbol the backend adds.
class TokenAvatar extends StatelessWidget {
  const TokenAvatar({required this.symbol, this.size = 40, super.key});

  final String symbol;
  final double size;

  @override
  Widget build(BuildContext context) {
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
