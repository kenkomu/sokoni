import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sokoni/core/config.dart';
import 'package:sokoni/data/passkey/cose.dart';
import 'package:sokoni/data/passkey/p256.dart';
import 'package:sokoni/data/passkey/passkey_authenticator.dart';
import 'package:sokoni/data/passkey/passkey_service.dart';
import 'package:sokoni/features/onboarding/passkey_controller.dart';

import 'support/fake_gateway.dart';

class _MockAuthenticator extends Mock implements PasskeyAuthenticatorService {}

const _config = AppConfig(
  apiBaseUrl: 'http://gateway.test',
  wsUrl: 'ws://gateway.test/v1/stream',
  chainId: AppConfig.monadTestnet,
  relyingPartyId: 'sokoni.app',
);

final _challengeHex = '0x${'ab' * 32}';

final _registered = RegisteredPasskey(
  credentialId: 'cred-1',
  publicKey: PublicKeyCoords(BigInt.from(1), BigInt.from(2)),
);

final _assertion = PasskeyAssertion(
  credentialId: 'cred-1',
  authenticatorData: Uint8List(37),
  clientDataJSON:
      '{"type":"webauthn.get","challenge":"x","origin":"https://sokoni.app"}',
  signature: Signature(BigInt.from(7), BigInt.from(9)),
);

/// A gateway that does everything right. [statuses] is what successive polls
/// of the operation return; the last one repeats forever.
FakeGateway _gateway({List<String> statuses = const ['submitted', 'landed']}) {
  var polls = 0;
  return FakeGateway()
    ..on(
      'POST',
      '/v1/accounts',
      (_) => (
        status: 201,
        body: {
          'credentialId': 'cred-1',
          'address': '0xACC7',
          'deployed': false,
        },
      ),
    )
    ..on(
      'GET',
      '/v1/config',
      (_) => (
        status: 200,
        body: {
          'chainId': 10143,
          'entryPoint': '0xEP',
          'sponsoredTokens': [
            {'address': '0xT', 'symbol': 'TST', 'decimals': 6},
          ],
        },
      ),
    )
    ..on(
      'POST',
      '/v1/ops',
      (_) => (
        status: 201,
        body: {
          'opId': 'op_1',
          'challenge': _challengeHex,
          'sender': '0xACC7',
          'deploysAccount': true,
          'expiresAt': '2026-09-10T12:05:00Z',
        },
      ),
    )
    ..on(
      'POST',
      '/v1/ops/op_1/submit',
      (_) => (
        status: 202,
        body: {
          'opId': 'op_1',
          'userOpHash': _challengeHex,
          'status': 'submitted',
        },
      ),
    )
    ..on('GET', '/v1/ops/op_1', (_) {
      final s = statuses[polls < statuses.length ? polls : statuses.length - 1];
      polls++;
      return (
        status: 200,
        body: {
          'opId': 'op_1',
          'status': s,
          if (s == 'landed') 'txHash': '0xtx',
          if (s == 'landed') 'blockNumber': 42,
          if (s == 'reverted') 'reason': 'transfer amount exceeds balance',
        },
      );
    });
}

_MockAuthenticator _authenticator() {
  final auth = _MockAuthenticator();
  when(
    () => auth.register(
      userId: any(named: 'userId'),
      userName: any(named: 'userName'),
      displayName: any(named: 'displayName'),
    ),
  ).thenAnswer((_) async => _registered);
  when(
    () => auth.sign(
      challenge: any(named: 'challenge'),
      allowCredentialIds: any(named: 'allowCredentialIds'),
    ),
  ).thenAnswer((_) async => _assertion);
  return auth;
}

PasskeyController _controller(
  FakeGateway gw,
  PasskeyAuthenticatorService auth, {
  Duration pollTimeout = const Duration(seconds: 5),
}) => PasskeyController(
  config: _config,
  service: auth,
  api: gw.api(),
  pollInterval: Duration.zero,
  pollTimeout: pollTimeout,
);

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(<String>[]);
  });

  test('create → account → send → watch it land', () async {
    final gw = _gateway();
    final c = _controller(gw, _authenticator());

    await c.createPasskey();
    expect(c.state.account?.address, '0xACC7');

    await c.send(to: '0xR', amount: '250000');

    expect(c.state.op?.status, 'landed');
    expect(c.state.op?.blockNumber, 42);
    expect(c.state.error, isNull);
    expect(c.state.isBusy, isFalse);

    // What actually went on the wire: an intent, then the assertion as-is.
    expect(gw.lastBody('POST', '/v1/ops')['intent'], {
      'kind': 'transfer',
      'token': '0xT',
      'to': '0xR',
      'amount': '250000',
    });
    expect(gw.lastBody('POST', '/v1/ops/op_1/submit'), _assertion.toJson());
  });

  test(
    'the biometric signs exactly the prepared challenge, with this key',
    () async {
      final auth = _authenticator();
      final c = _controller(_gateway(), auth);

      await c.createPasskey();
      await c.send(to: '0xR', amount: '1');

      final captured =
          verify(
            () => auth.sign(
              challenge: captureAny(named: 'challenge'),
              allowCredentialIds: captureAny(named: 'allowCredentialIds'),
            ),
          ).captured;
      expect(captured[0], Uint8List.fromList(List.filled(32, 0xab)));
      // Only the registered credential may answer; another passkey on the same
      // device must not be offered.
      expect(captured[1], ['cred-1']);
    },
  );

  // Calling an unconfirmed operation "failed" could make someone send twice.
  test(
    'an unconfirmed operation is reported honestly, not as a failure',
    () async {
      final c = _controller(
        _gateway(statuses: const ['submitted']),
        _authenticator(),
        pollTimeout: Duration.zero,
      );

      await c.createPasskey();
      await c.send(to: '0xR', amount: '1');

      expect(c.state.op?.status, 'submitted');
      expect(c.state.error, contains('not confirmed yet'));
      expect(c.state.error, isNot(contains('fail')));
      expect(c.state.isBusy, isFalse);
    },
  );

  test('a revert is reported with its reason', () async {
    final c = _controller(
      _gateway(statuses: const ['submitted', 'reverted']),
      _authenticator(),
    );

    await c.createPasskey();
    await c.send(to: '0xR', amount: '1');

    expect(c.state.op?.status, 'reverted');
    expect(c.state.error, contains('reverted'));
    expect(c.state.error, contains('exceeds balance'));
  });

  test('a gateway refusal shows its own message, and never prompts', () async {
    final gw =
        _gateway()..on(
          'POST',
          '/v1/ops',
          (_) => (
            status: 400,
            body: {
              'error': 'insufficient_balance',
              'message': 'not enough TST — deposit or reduce the amount',
            },
          ),
        );
    final auth = _authenticator();
    final c = _controller(gw, auth);

    await c.createPasskey();
    await c.send(to: '0xR', amount: '999');

    expect(c.state.error, 'not enough TST — deposit or reduce the amount');
    // Nothing was prepared, so nothing may be signed.
    verifyNever(
      () => auth.sign(
        challenge: any(named: 'challenge'),
        allowCredentialIds: any(named: 'allowCredentialIds'),
      ),
    );
  });

  test(
    'if the gateway is down at signup, the key is kept and only the lookup retries',
    () async {
      var up = false;
      final gw =
          _gateway()..on('POST', '/v1/accounts', (_) {
            if (!up) throw const SocketException('Connection refused');
            return (
              status: 201,
              body: {
                'credentialId': 'cred-1',
                'address': '0xACC7',
                'deployed': false,
              },
            );
          });
      final auth = _authenticator();
      final c = _controller(gw, auth);

      await c.createPasskey();
      expect(c.state.registered, isNotNull);
      expect(c.state.account, isNull);
      expect(c.state.error, contains('Could not reach the gateway'));

      up = true;
      await c.registerAccount();
      expect(c.state.account?.address, '0xACC7');
      expect(c.state.error, isNull);

      // One passkey, not two. A second prompt would orphan a credential in the
      // user's password manager.
      verify(
        () => auth.register(
          userId: any(named: 'userId'),
          userName: any(named: 'userName'),
          displayName: any(named: 'displayName'),
        ),
      ).called(1);
    },
  );

  test('a watch that outlives the screen stops quietly', () async {
    final c = PasskeyController(
      config: _config,
      service: _authenticator(),
      api: _gateway(statuses: const ['submitted']).api(),
      pollInterval: const Duration(milliseconds: 5),
      pollTimeout: const Duration(seconds: 5),
    );

    await c.createPasskey();
    final sending = c.send(to: '0xR', amount: '1');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    c.dispose();

    // Must finish without "used after being disposed".
    await sending;
  });
}
