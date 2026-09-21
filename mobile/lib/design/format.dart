import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// `0xD3918f...583287` — enough to recognise, never enough to mistake for
/// another address.
String shortAddress(String address) {
  if (address.length <= 12) return address;
  return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
}

/// Puts the **full** address on the clipboard, whatever shortened form the
/// person was looking at when they tapped — the reason to copy one is to
/// paste it somewhere that needs all 42 characters, so copying the elided
/// version would be worse than not offering it.
///
/// Confirms visibly: a clipboard write gives no feedback of its own, and
/// "did that work?" on an address you're about to send money to is exactly
/// the doubt worth spending a snackbar on.
Future<void> copyAddress(BuildContext context, String address) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: address));
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text('Address copied — ${shortAddress(address)}'),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// Formats a market price string for display.
///
/// A price is a ratio (quote per base), not a token amount — it is never
/// safe to run through [Money], whose whole contract is "this many base
/// units of *this* token, at *this* token's own decimals". Feeding it a
/// price string threw the moment real Kuru data arrived: `px`/`close` come
/// back at a fixed 18-decimal scale (`kuruVaultPricePrecision` on the Go
/// side, see backend/internal/store/postgres.go), independent of the
/// quote token's own decimals (6 for AUSD/USDC), and Money.parse refuses
/// to silently truncate anything with more fractional digits than the
/// scale it was given — exactly the crash this replaces.
///
/// [maxDecimals] only rounds for *display*; the underlying value is never
/// fed back into arithmetic from this string, so lossy rounding here is
/// safe in a way it would not be for a balance.
String formatPrice(String raw, {int maxDecimals = 6}) {
  final value = Decimal.parse(raw);
  return value.round(scale: maxDecimals).toString();
}

/// A stable accent colour for a token symbol, so the same symbol always
/// draws the same colour without a per-token icon asset to maintain.
Color colorForSymbol(String symbol) {
  const palette = [
    Color(0xFF0063F5),
    Color(0xFF21BF73),
    Color(0xFF8452D5),
    Color(0xFFD98A2B),
    Color(0xFF2BA3D9),
    Color(0xFFD90429),
  ];
  final index = symbol.codeUnits.fold<int>(0, (a, b) => a + b) % palette.length;
  return palette[index];
}
