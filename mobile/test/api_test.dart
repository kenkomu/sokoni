import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/data/api/sokoni_api.dart';
import 'package:sokoni/data/passkey/cose.dart';
import 'package:sokoni/data/passkey/p256.dart';
import 'package:sokoni/data/passkey/passkey_service.dart';

import 'support/fake_gateway.dart';

final challengeHex = '0x${'ab' * 32}';

/// The phone ↔ gateway contract, pinned from the Dart side.
/// backend/internal/gateway/http_test.go pins the same shapes from the Go side.
void main() {
  group('registerAccount', () {
    test('sends both coordinates zero-padded to 32 bytes', () async {
      final gw =
          FakeGateway()..on(
            'POST',
            '/v1/accounts',
            (_) => (
              status: 201,
              body: {
                'credentialId': 'cred-1',
                'address': '0x000000000000000000000000000000000000ACC7',
                'deployed': false,
              },
            ),
          );

      // A small x has a lot of leading zeros. The gateway must still see a
      // full 32-byte value, which is exactly what a strict hex decoder there
      // would once have refused.
      final account = await gw.api().registerAccount(
        credentialId: 'cred-1',
        publicKey: PublicKeyCoords(BigInt.from(0xab), BigInt.from(0xcd)),
      );

      final body = gw.lastBody('POST', '/v1/accounts');
      expect(body['credentialId'], 'cred-1');
      expect(body['x'], '0x${'0' * 62}ab');
      expect(body['y'], '0x${'0' * 62}cd');
      expect(account.address, '0x000000000000000000000000000000000000ACC7');
      expect(account.deployed, isFalse);
    });
  });

  group('prepareTransfer', () {
    test('sends an intent, never calldata', () async {
      final gw = FakeGateway()..on('POST', '/v1/ops', (_) => _prepared());

      await gw.api().prepareTransfer(
        credentialId: 'cred-1',
        token: '0xT',
        to: '0xR',
        amount: '250000',
      );

      final body = gw.lastBody('POST', '/v1/ops');
      expect(body['intent'], {
        'kind': 'transfer',
        'token': '0xT',
        'to': '0xR',
        'amount': '250000',
      });
      expect(body.containsKey('callData'), isFalse);
    });

    test('decodes the challenge to exactly the 32 bytes to sign', () async {
      final gw = FakeGateway()..on('POST', '/v1/ops', (_) => _prepared());
      final op = await gw.api().prepareTransfer(
        credentialId: 'c',
        token: 't',
        to: 'r',
        amount: '1',
      );
      expect(op.challenge, Uint8List.fromList(List.filled(32, 0xab)));
      expect(op.deploysAccount, isTrue);
      expect(op.expiresAt.isUtc, isTrue);
    });

    test('refuses a challenge that is not 32 bytes rather than sign it', () {
      final gw =
          FakeGateway()
            ..on('POST', '/v1/ops', (_) => _prepared(challenge: '0xabcd'));
      expect(
        gw.api().prepareTransfer(
          credentialId: 'c',
          token: 't',
          to: 'r',
          amount: '1',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses a challenge with a sign character smuggled in', () {
      // int.parse(radix: 16) would read "-1" as a byte; the regex refuses it.
      final gw =
          FakeGateway()..on(
            'POST',
            '/v1/ops',
            (_) => _prepared(challenge: '0x-1${'ab' * 31}'),
          );
      expect(
        gw.api().prepareTransfer(
          credentialId: 'c',
          token: 't',
          to: 'r',
          amount: '1',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('submit', () {
    test('posts the assertion exactly as toJson emits it', () async {
      final gw =
          FakeGateway()..on(
            'POST',
            '/v1/ops/op_1/submit',
            (_) => (
              status: 202,
              body: {
                'opId': 'op_1',
                'userOpHash': challengeHex,
                'status': 'submitted',
              },
            ),
          );

      final assertion = PasskeyAssertion(
        credentialId: 'cred-1',
        authenticatorData: Uint8List(37),
        clientDataJSON:
            '{"type":"webauthn.get","challenge":"q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s","origin":"https://sokoni.app"}',
        signature: Signature(BigInt.from(7), BigInt.from(9)),
      );

      final result = await gw.api().submit(opId: 'op_1', assertion: assertion);

      expect(gw.lastBody('POST', '/v1/ops/op_1/submit'), assertion.toJson());
      expect(result.status, 'submitted');
    });
  });

  group('status', () {
    test('knows which states are final', () {
      for (final s in ['landed', 'reverted', 'expired']) {
        expect(OpStatus(opId: 'o', status: s).isFinal, isTrue, reason: s);
      }
      for (final s in ['prepared', 'submitted']) {
        expect(OpStatus(opId: 'o', status: s).isFinal, isFalse, reason: s);
      }
    });

    test('parses a landed receipt', () async {
      final gw =
          FakeGateway()..on(
            'GET',
            '/v1/ops/op_1',
            (_) => (
              status: 200,
              body: {
                'opId': 'op_1',
                'status': 'landed',
                'txHash': '0xtx',
                'blockNumber': 42,
              },
            ),
          );
      final s = await gw.api().status('op_1');
      expect(s.landed, isTrue);
      expect(s.blockNumber, 42);
    });
  });

  group('errors', () {
    test('carry the message the gateway wrote for a person', () async {
      final gw =
          FakeGateway()..on(
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

      await expectLater(
        gw.api().prepareTransfer(
          credentialId: 'c',
          token: 't',
          to: 'r',
          amount: '1',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.code, 'code', 'insufficient_balance')
              .having((e) => e.message, 'message', contains('deposit')),
        ),
      );
    });

    test('an unreachable gateway says so, naming where it looked', () async {
      final gw =
          FakeGateway()..on(
            'GET',
            '/v1/config',
            (_) => throw const SocketException('Connection refused'),
          );
      await expectLater(
        gw.api().config(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'unreachable')
              .having((e) => e.message, 'message', contains('gateway.test')),
        ),
      );
    });
  });
}

Reply _prepared({String? challenge}) => (
  status: 201,
  body: {
    'opId': 'op_1',
    'challenge': challenge ?? challengeHex,
    'sender': '0x000000000000000000000000000000000000ACC7',
    'deploysAccount': true,
    'expiresAt': '2026-09-10T12:05:00Z',
  },
);
