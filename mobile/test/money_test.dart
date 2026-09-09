import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/core/money.dart';

void main() {
  test('parses and renders without losing precision', () {
    expect(Money.parse('1234.56789', 6).toString(), '1234.56789');
    expect(Money.parse('0.000001', 6).toString(), '0.000001');
    expect(Money.parse('-2.25', 6).toString(), '-2.25');
  });

  test('refuses more precision than the scale allows', () {
    // AUSD is 6 decimals. Silently truncating a user's amount is a money bug.
    expect(() => Money.parse('1.0000001', 6), throwsFormatException);
  });

  test('refuses to add mismatched scales', () {
    final ausd = Money.parse('1', 6);
    final mon = Money.parse('1', 18);
    expect(() => ausd + mon, throwsArgumentError);
  });
}
