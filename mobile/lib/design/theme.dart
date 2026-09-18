import 'package:flutter/material.dart';

/// The visual system.
///
/// A trading screen is read at a glance under stress, so the palette does two
/// jobs and no more: a single accent for actions, and semantic colours for
/// direction (bid/ask, up/down). Those are deliberately not the accent — a
/// green button and a green price must never be confusable.
abstract final class SokoniTheme {
  // Literal tokens from the Figma UI kit this was built from (Crypto Trading
  // App UI Kit — Community), not an approximation of them.
  static const _primary = Color(0xFF0063F5);
  static const _bidGreen = Color(0xFF21BF73);
  static const _askRed = Color(0xFFD90429);

  // The kit's own light surface tokens ("Bg"/"Alt BG"/text/border).
  static const _lightBg = Color(0xFFF8F9FA);
  static const _lightCard = Color(0xFFFFFFFF);
  static const _lightText1 = Color(0xFF212529);
  static const _lightText3 = Color(0xFF6C757D);
  static const _lightBorder = Color(0xFFDFE2E4);

  // The kit has no dark variant to copy, so dark surfaces come from a
  // financial-dashboard-specific dark palette instead of Material 3's seed
  // algorithm — seed-derived dark schemes tend toward a washed-out navy that
  // reads as "generic app," not "trading terminal."
  static const _darkBg = Color(0xFF020617);
  static const _darkCard = Color(0xFF0E1223);
  static const _darkText1 = Color(0xFFF8FAFC);
  static const _darkText3 = Color(0xFF94A3B8);
  static const _darkBorder = Color(0xFF334155);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    var scheme = ColorScheme.fromSeed(
      seedColor: _primary,
      brightness: brightness,
    ).copyWith(primary: _primary, onPrimary: Colors.white);
    scheme = scheme.copyWith(
      surface: dark ? _darkBg : _lightBg,
      onSurface: dark ? _darkText1 : _lightText1,
      onSurfaceVariant: dark ? _darkText3 : _lightText3,
      outline: dark ? _darkBorder : _lightBorder,
      surfaceContainerLow: dark ? _darkCard : _lightCard,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      // Prices, sizes and balances must line up in columns. Typography's
      // `.black`/`.white` split matters here — a fixed choice regardless of
      // brightness renders dark-on-dark or light-on-light wherever a widget
      // doesn't set its own text colour.
      textTheme: (brightness == Brightness.dark
              ? Typography.material2021().white
              : Typography.material2021().black)
          .apply(fontFamily: 'Inter'),
      extensions: [SokoniColors(bid: _bidGreen, ask: _askRed)],
    );
  }
}

/// Direction colours, carried as a theme extension so widgets never hardcode a
/// literal that only works in one brightness.
class SokoniColors extends ThemeExtension<SokoniColors> {
  const SokoniColors({required this.bid, required this.ask});

  final Color bid;
  final Color ask;

  @override
  SokoniColors copyWith({Color? bid, Color? ask}) =>
      SokoniColors(bid: bid ?? this.bid, ask: ask ?? this.ask);

  @override
  SokoniColors lerp(ThemeExtension<SokoniColors>? other, double t) {
    if (other is! SokoniColors) return this;
    return SokoniColors(
      bid: Color.lerp(bid, other.bid, t)!,
      ask: Color.lerp(ask, other.ask, t)!,
    );
  }
}

/// Digits that line up. Used for every price, size and balance.
const tabularFigures = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
