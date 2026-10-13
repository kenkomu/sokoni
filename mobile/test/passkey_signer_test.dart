import 'dart:typed_data';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sokoni/core/config.dart';
import 'package:sokoni/data/passkey/cose.dart';
import 'package:sokoni/data/passkey/p256.dart';
import 'package:sokoni/data/passkey/passkey_authenticator.dart';
import 'package:sokoni/data/passkey/passkey_service.dart';
import 'package:sokoni/data/passkey/passkey_signer.dart';
import 'package:sokoni/features/onboarding/mera_controller.dart';

import 'support/fake_gateway.dart';

class _MockAuthenticator extends Mock implements PasskeyAuthenticatorService {}

const _config = AppConfig(
  apiBaseUrl: 'http://gateway.test',
  wsUrl: 'ws://gateway.test/v1/stream',
  chainId: AppConfig.monadTestnet,
  relyingPartyId: 'sokoni.app',
);

final _challengeHex = '0x${'ab' * 32}';

final _passkey = RegisteredPasskey(
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

FakeGateway _gateway() =>
    FakeGateway()
      ..on(
        'POST',
        '/v1/accounts',
        (_) => (
          status: 201,
          body: {
            'credentialId': 'cred-1',
            'address': '0xACC7',
            'deployed': true,
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
            'deploysAccount': false,
            'expiresAt': '2026-10-13T12:05:00Z',
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
      ..on(
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

void main() {
  late _MockAuthenticator auth;

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(<String>[]);
  });

  setUp(() {
    auth = _MockAuthenticator();
    when(
      () => auth.sign(
        challenge: any(named: 'challenge'),
        allowCredentialIds: any(named: 'allowCredentialIds'),
      ),
    ).thenAnswer((_) async => _assertion);
  });

  test(
    'a passkey account trades through /v1/ops, approved by the biometric prompt',
    () async {
      final gw = _gateway();
      final controller = MeraController(
        config: _config,
        api: gw.api(),
        pollInterval: Duration.zero,
      );
      await controller.useWallet(
        PasskeySigner(_passkey, config: _config, service: auth),
      );
      expect(controller.state.account?.address, '0xACC7');
      expect(gw.lastBody('POST', '/v1/accounts')['credentialId'], 'cred-1');

      await controller.sendTrade(
        market: 'BTC-USDC',
        side: 'buy',
        amountHuman: '15',
        decimals: 6,
      );

      final prepared = gw.lastBody('POST', '/v1/ops');
      expect(prepared['credentialId'], 'cred-1');
      expect(prepared['intent'], {
        'kind': 'trade',
        'market': 'BTC-USDC',
        'side': 'buy',
        'amount': '15000000',
      });

      final captured =
          verify(
            () => auth.sign(
              challenge: captureAny(named: 'challenge'),
              allowCredentialIds: captureAny(named: 'allowCredentialIds'),
            ),
          ).captured;
      expect(captured[0], hasLength(32));
      expect(captured[1], ['cred-1']);

      expect(
        gw.lastBody('POST', '/v1/ops/op_1/submit')['credentialId'],
        'cred-1',
      );
      expect(controller.state.op?.landed, isTrue);
      expect(controller.state.error, isNull);
      expect(gw.count('POST', '/v1/mera/ops'), 0);
    },
  );

  test('the stored credential survives a round trip, key and all', () async {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    final store = PasskeyCredentialStore();
    expect(await store.load(), isNull);

    final passkey = RegisteredPasskey(
      credentialId: 'cred-xyz',
      publicKey: PublicKeyCoords(BigInt.from(3) << 250, BigInt.from(5)),
    );
    await store.save(passkey);

    final loaded = await store.load();
    expect(loaded?.credentialId, 'cred-xyz');
    expect(loaded?.publicKey.xHex, passkey.publicKey.xHex);
    expect(loaded?.publicKey.yHex, passkey.publicKey.yHex);
  });
}
