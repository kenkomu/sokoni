import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/core/config.dart';
import 'package:sokoni/data/mera/mera_key_service.dart';
import 'package:sokoni/features/onboarding/mera_controller.dart';
import 'package:web3dart/crypto.dart';

import 'support/fake_gateway.dart';

const _config = AppConfig(
  apiBaseUrl: 'http://gateway.test',
  wsUrl: 'ws://gateway.test/v1/stream',
  chainId: AppConfig.monadTestnet,
  relyingPartyId: 'sokoni.app',
);

final _challengeHex = '0x${'ab' * 32}';

/// A gateway that does everything right, keyed by owner address rather than
/// credential id — the Mera path's twin of PasskeyController's `_gateway`.
/// [owner] must match what [MeraKeyService.addressOf] derives from the key
/// [TestFlutterSecureStoragePlatform] hands back, since the controller
/// submits whatever address it computed, and a fake that only recognised a
/// hardcoded one would pass for the wrong reason.
FakeGateway _gateway({
  required String owner,
  List<String> statuses = const ['submitted', 'landed'],
}) {
  var polls = 0;
  return FakeGateway()
    ..on(
      'POST',
      '/v1/mera/accounts',
      (_) => (
        status: 201,
        body: {'owner': owner, 'address': '0xACC7', 'deployed': false},
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
      '/v1/mera/ops',
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
      '/v1/mera/ops/op_1/submit',
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

void main() {
  // MeraKeyService talks to FlutterSecureStorage through the platform
  // interface; TestFlutterSecureStoragePlatform (shipped by the package
  // itself for exactly this) backs it with a plain in-memory map instead of
  // a real Keystore/Keychain channel.
  late Map<String, String> storageData;
  late MeraKeyService keyService;
  late String owner;

  setUp(() async {
    storageData = {};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      storageData,
    );
    keyService = MeraKeyService();
    // Precompute the address a fresh key will resolve to isn't possible
    // (keygen is random) — instead generate once here and read it back via
    // addressOf, then throw the key away; the controller under test
    // generates its own, and each gateway is built to answer whatever
    // address that turns out to be. Simpler: generate through the same
    // storage now, so both the gateway (via [owner]) and the controller
    // resolve to the identical key.
    final key = await keyService.generate();
    owner = keyService.addressOf(key);
  });

  MeraController controller(FakeGateway gw) => MeraController(
    config: _config,
    keyService: keyService,
    api: gw.api(),
    pollInterval: Duration.zero,
    pollTimeout: const Duration(seconds: 5),
  );

  test('load key → account → send → watch it land', () async {
    final gw = _gateway(owner: owner);
    final c = controller(gw);

    await c.loadOrCreateKey();
    expect(c.state.account?.address, '0xACC7');
    expect(c.state.key, isNotNull);

    await c.send(to: '0xR', amount: '0.25');

    expect(c.state.op?.status, 'landed');
    expect(c.state.op?.blockNumber, 42);
    expect(c.state.error, isNull);
    expect(c.state.isBusy, isFalse);

    expect(gw.lastBody('POST', '/v1/mera/ops')['intent'], {
      'kind': 'transfer',
      'token': '0xT',
      'to': '0xR',
      'amount': '250000',
    });
    final submitted = gw.lastBody('POST', '/v1/mera/ops/op_1/submit');
    expect(submitted['owner'], owner);
    expect(submitted['signature'], startsWith('0x'));
    // 65 bytes: r(32) + s(32) + v(1).
    expect((submitted['signature'] as String).length, 2 + 65 * 2);
  });

  test(
    'load key → account → sendTrade → watch it land, amount scaled by '
    'the given decimals not the sponsored token\'s',
    () async {
      final gw = _gateway(owner: owner);
      final c = controller(gw);

      await c.loadOrCreateKey();

      // 18 decimals (e.g. ETH-USDC's base asset), not the sponsored token's
      // 6 -- proves sendTrade uses the decimals it's given, not state.token.
      await c.sendTrade(
        market: 'ETH-USDC',
        side: 'sell',
        amountHuman: '0.01',
        decimals: 18,
      );

      expect(c.state.op?.status, 'landed');
      expect(c.state.error, isNull);
      expect(gw.lastBody('POST', '/v1/mera/ops')['intent'], {
        'kind': 'trade',
        'market': 'ETH-USDC',
        'side': 'sell',
        'amount': '10000000000000000', // 0.01 * 1e18
      });
      final submitted = gw.lastBody('POST', '/v1/mera/ops/op_1/submit');
      expect(submitted['owner'], owner);
      expect(submitted['signature'], startsWith('0x'));
    },
  );

  test('an existing on-device key is reused, not regenerated', () async {
    final gw = _gateway(owner: owner);
    final c1 = controller(gw);
    await c1.loadOrCreateKey();
    final first = c1.state.key!.privateKeyInt;

    final c2 = controller(_gateway(owner: owner));
    await c2.loadOrCreateKey();

    expect(c2.state.key!.privateKeyInt, first);
  });

  test(
    'the signature recovers to the account owner, over the exact prepared '
    'challenge, EIP-191-wrapped — the same check '
    'backend/internal/account/mera.go\'s VerifyMeraSignature does',
    () async {
      final gw = _gateway(owner: owner);
      final c = controller(gw);
      await c.loadOrCreateKey();
      await c.send(to: '0xR', amount: '1');

      final sigHex = gw.lastBody(
        'POST',
        '/v1/mera/ops/op_1/submit',
      )['signature'] as String;
      final sigBytes = hexToBytes(sigHex);
      expect(sigBytes.length, 65);

      final challenge = Uint8List.fromList(List.filled(32, 0xab));
      final prefixed = Uint8List.fromList(
        utf8.encode('\x19Ethereum Signed Message:\n32') + challenge,
      );
      final digest = keccak256(prefixed);

      // v is already 27 or 28 — web3dart's signPersonalMessageToUint8List
      // (same as backend/internal/account/mera.go's VerifyMeraSignature)
      // emits it in that range directly, so it goes to ecRecover unchanged.
      // Forcing it to a fixed value here would make this test pass or fail
      // by luck of which recovery id a given random key happened to need.
      final v = sigBytes[64];
      // r and s are unsigned 256-bit values, so this needs
      // bytesToUnsignedInt — bytesToInt (used elsewhere for private keys) is
      // two's-complement and misreads any r/s whose top byte is >= 0x80 as
      // negative, which happens for about half of all random keys and
      // crashes ecRecover's internal unsignedIntToBytes assertion.
      final recovered = ecRecover(
        digest,
        MsgSignature(
          bytesToUnsignedInt(sigBytes.sublist(0, 32)),
          bytesToUnsignedInt(sigBytes.sublist(32, 64)),
          v,
        ),
      );
      final recoveredAddress = '0x${bytesToHex(publicKeyToAddress(recovered))}';
      expect(recoveredAddress.toLowerCase(), owner.toLowerCase());
    },
  );

  test('a malformed amount is refused before it ever reaches the gateway', () async {
    final gw = _gateway(owner: owner);
    final c = controller(gw);
    await c.loadOrCreateKey();

    await c.send(to: '0xR', amount: 'not a number');

    expect(c.state.error, contains('digits'));
    expect(gw.count('POST', '/v1/mera/ops'), 0);
  });

  test(
    'if the gateway is down at signup, the key is kept and only the lookup retries',
    () async {
      var up = false;
      final gw =
          _gateway(owner: owner)..on('POST', '/v1/mera/accounts', (_) {
            if (!up) throw const SocketException('Connection refused');
            return (
              status: 201,
              body: {'owner': owner, 'address': '0xACC7', 'deployed': false},
            );
          });
      final c = controller(gw);

      await c.loadOrCreateKey();
      expect(c.state.key, isNotNull);
      expect(c.state.account, isNull);
      expect(c.state.error, contains('Could not reach the gateway'));

      up = true;
      await c.registerAccount();
      expect(c.state.account?.address, '0xACC7');
      expect(c.state.error, isNull);
    },
  );

  test('a revert is reported with its reason', () async {
    final c = controller(
      _gateway(owner: owner, statuses: const ['submitted', 'reverted']),
    );

    await c.loadOrCreateKey();
    await c.send(to: '0xR', amount: '1');

    expect(c.state.op?.status, 'reverted');
    expect(c.state.error, contains('reverted'));
    expect(c.state.error, contains('exceeds balance'));
  });
}
