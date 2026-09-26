import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/data/api/sokoni_api.dart';
import 'package:sokoni/features/portfolio/portfolio_controller.dart';

AccountBalance _balance(String symbol, int decimals, String amount) =>
    AccountBalance(
      token: SponsoredToken(
        address: '0x$symbol',
        symbol: symbol,
        decimals: decimals,
      ),
      amount: amount,
    );

void main() {
  test('stablecoins count at 1:1 with no market price needed', () {
    final (total, allPriced) = totalValueUsdc([
      _balance('USDC', 6, '5000000'),
      _balance('AUSD', 6, '2500000'),
    ], const {});
    expect(total, Decimal.parse('7.5'));
    expect(allPriced, isTrue);
  });

  test('a priced token is converted at its market price', () {
    // 0.5 BTC at 80,000 USDC/BTC = 40,000 USDC.
    final (total, allPriced) = totalValueUsdc(
      [_balance('BTC', 8, '50000000')],
      {'BTC': Decimal.parse('80000')},
    );
    expect(total, Decimal.parse('40000'));
    expect(allPriced, isTrue);
  });

  test('a held token with no market price is excluded and flagged', () {
    final (total, allPriced) = totalValueUsdc(
      [_balance('USDC', 6, '1000000'), _balance('XAUt0', 6, '1000000')],
      const {}, // XAUt0 unpriced
    );
    // Only the USDC leg counts -- a silently-included zero for XAUt0 would
    // be indistinguishable from "genuinely worth nothing", which is false.
    expect(total, Decimal.one);
    expect(allPriced, isFalse);
  });

  test('a zero balance in an unpriced token does not trip allPriced', () {
    final (total, allPriced) = totalValueUsdc([
      _balance('USDC', 6, '1000000'),
      _balance('XAUt0', 6, '0'),
    ], const {});
    expect(total, Decimal.one);
    expect(allPriced, isTrue);
  });
}
