import 'package:decimal/decimal.dart';

/// A monetary amount.
///
/// Mirrors the backend's `money.Amount`: an integer of base units plus the
/// scale those units are in. Never a `double` — 0.1 + 0.2 is a rounding bug
/// that costs real money, and Dart doubles lose integer precision above 2^53,
/// which an 18-decimal token passes trivially.
///
/// Amounts cross the API as strings for the same reason.
class Money implements Comparable<Money> {
  const Money._(this.units, this.decimals);

  final BigInt units;
  final int decimals;

  static Money zero(int decimals) => Money._(BigInt.zero, decimals);

  /// Parses a plain decimal string. Throws rather than silently truncating an
  /// amount with more precision than the scale allows.
  factory Money.parse(String value, int decimals) {
    final s = value.trim();
    if (s.isEmpty) throw FormatException('empty amount');

    final negative = s.startsWith('-');
    final body = negative ? s.substring(1) : s;
    final dot = body.indexOf('.');
    final whole = dot == -1 ? body : body.substring(0, dot);
    var frac = dot == -1 ? '' : body.substring(dot + 1);

    if (frac.length > decimals) {
      throw FormatException('$value has more precision than $decimals decimals');
    }
    frac = frac.padRight(decimals, '0');

    final units = BigInt.parse('${whole.isEmpty ? '0' : whole}$frac');
    return Money._(negative ? -units : units, decimals);
  }

  bool get isZero => units == BigInt.zero;
  bool get isNegative => units.isNegative;

  void _sameScale(Money other) {
    if (other.decimals != decimals) {
      throw ArgumentError('scale mismatch: $decimals vs ${other.decimals}');
    }
  }

  Money operator +(Money other) {
    _sameScale(other);
    return Money._(units + other.units, decimals);
  }

  Money operator -(Money other) {
    _sameScale(other);
    return Money._(units - other.units, decimals);
  }

  @override
  int compareTo(Money other) {
    _sameScale(other);
    return units.compareTo(other.units);
  }

  /// For display only — never feed this back into arithmetic.
  Decimal toDecimal() => Decimal.parse(toString());

  @override
  String toString() {
    final negative = units.isNegative;
    var digits = units.abs().toString();
    if (decimals == 0) return '${negative ? '-' : ''}$digits';

    digits = digits.padLeft(decimals + 1, '0');
    final whole = digits.substring(0, digits.length - decimals);
    var frac = digits.substring(digits.length - decimals).replaceAll(RegExp(r'0+$'), '');
    return '${negative ? '-' : ''}$whole${frac.isEmpty ? '' : '.$frac'}';
  }

  @override
  bool operator ==(Object other) =>
      other is Money && other.units == units && other.decimals == decimals;

  @override
  int get hashCode => Object.hash(units, decimals);
}
