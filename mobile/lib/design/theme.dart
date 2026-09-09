import 'package:flutter/material.dart';

/// The visual system.
///
/// A trading screen is read at a glance under stress, so the palette does two
/// jobs and no more: a single accent for actions, and semantic colours for
/// direction (bid/ask, up/down). Those are deliberately not the accent — a
/// green button and a green price must never be confusable.
abstract final class SokoniTheme {
  static const _bidGreen = Color(0xFF0F9D76);
  static const _askRed = Color(0xFFD2503C);
  static const _accent = Color(0xFF3B6FE0);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      // Prices, sizes and balances must line up in columns.
      textTheme: Typography.material2021().black.apply(
            fontFamily: 'Inter',
          ),
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
