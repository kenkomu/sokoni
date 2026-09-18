import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/design/format.dart';

void main() {
  group('formatPrice', () {
    // The exact shape real Kuru data comes back in: numeric(38,18) in
    // Postgres, trailing-zero-padded to 18 places regardless of how many
    // digits are actually significant. This is what crashed Money.parse on
    // a real device the moment real trade data replaced demo data.
    test('trims a full 18-decimal Postgres numeric to 6 places', () {
      expect(formatPrice('0.024236000000000000'), '0.024236');
      expect(formatPrice('0.023788000000000000'), '0.023788');
    });

    test('rounds rather than truncates past the display precision', () {
      // 7th decimal is 5, rounds the 6th up.
      expect(formatPrice('0.0238885000000000'), '0.023889');
    });

    test('handles a value with no fractional part', () {
      expect(formatPrice('5'), '5');
    });

    test('handles a large whole number unaffected by rounding', () {
      // What the old pricePrecision-only bug actually produced for a real
      // trade before it was fixed -- formatPrice must not choke on it even
      // though nothing should emit this anymore.
      expect(formatPrice('237580000'), '237580000');
    });

    test('respects a custom maxDecimals', () {
      expect(formatPrice('0.123456789', maxDecimals: 2), '0.12');
    });
  });
}
