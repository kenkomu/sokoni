import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/core/config.dart';
import 'package:sokoni/features/portfolio/portfolio_controller.dart';

import '../../support/fake_gateway.dart';

const _config = AppConfig(
  apiBaseUrl: 'http://gateway.test',
  wsUrl: 'ws://gateway.test/v1/stream',
  chainId: AppConfig.monadTestnet,
  relyingPartyId: 'sokoni.app',
);

Reply _balancesOf(String amount) => (
  status: 200,
  body: {
    'address': '0xACC7',
    'balances': [
      {
        'token': {'address': '0xTOK', 'symbol': 'AUSD', 'decimals': 6},
        'amount': amount,
      },
    ],
  },
);

void main() {
  test('load reads the account balances', () async {
    final gw =
        FakeGateway()..on(
          'GET',
          '/v1/accounts/0xACC7/balances',
          (_) => _balancesOf('5000000'),
        );
    final c = PortfolioController(
      config: _config,
      accountAddress: '0xACC7',
      api: gw.api(),
    );

    await c.load();

    expect(c.state.error, isNull);
    expect(c.state.balances, hasLength(1));
    expect(c.state.balances!.single.token.symbol, 'AUSD');
    expect(c.state.balances!.single.amount, '5000000');
  });

  test('an account with no address never calls the gateway', () async {
    final gw = FakeGateway();
    final c = PortfolioController(
      config: _config,
      accountAddress: null,
      api: gw.api(),
    );

    await c.load();

    // The debug preview account has no registered address to ask about;
    // asking anyway would just be a confusing 404.
    expect(gw.requests, isEmpty);
    expect(c.state.balances, isEmpty);
    expect(c.state.error, isNull);
  });

  test('a gateway failure surfaces its message', () async {
    final gw =
        FakeGateway()..on(
          'GET',
          '/v1/accounts/0xACC7/balances',
          (_) => (
            status: 502,
            body: {
              'error': 'no_chain',
              'message': 'could not read the token balance',
            },
          ),
        );
    final c = PortfolioController(
      config: _config,
      accountAddress: '0xACC7',
      api: gw.api(),
    );

    await c.load();

    expect(c.state.balances, isNull);
    expect(c.state.error, 'could not read the token balance');
  });
}
