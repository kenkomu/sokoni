import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sokoni/data/passkey/cose.dart';
import 'package:sokoni/data/passkey/p256.dart';
import 'package:sokoni/data/passkey/passkey_service.dart';

/// These run against the SAME fixture the Solidity tests use
/// (contracts/test/fixtures/webauthn_vector.json, produced by
/// contracts/script/gen_webauthn_vector.py). If the client and the contract
/// ever disagree about these bytes, one of these suites goes red — which is the
/// point. Each side being self-consistently wrong is the failure mode that
/// would otherwise only show up on a real device against a real chain.
void main() {
  late Map<String, dynamic> v;

  setUpAll(() {
    v =
        jsonDecode(
              File('test/fixtures/webauthn_vector.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
  });

  Uint8List hex(String s) {
    final clean = s.startsWith('0x') ? s.substring(2) : s;
    return Uint8List.fromList([
      for (var i = 0; i < clean.length; i += 2)
        int.parse(clean.substring(i, i + 2), radix: 16),
    ]);
  }

  BigInt big(String s) => BigInt.parse(s.substring(2), radix: 16);

  group('DER signature parsing', () {
    test('extracts r and s the contract expects', () {
      final sig = parseDerSignature(hex(v['derSignature'] as String));
      expect(sig.r, big(v['r'] as String));
      expect(sig.s, big(v['s'] as String));
      expect(sig.isLowS, isTrue);
    });

    test('normalises a high-s signature to the same low-s value', () {
      // The authenticator may return either form. Monad's precompile accepts
      // both, and SokoniAccount rejects the high one, so the client must
      // normalise or roughly half of all signatures would be refused.
      final low = parseDerSignature(hex(v['derSignature'] as String));
      final high = parseDerSignature(hex(v['derSignatureHighS'] as String));
      expect(
        high.s,
        low.s,
        reason: 'high-s must normalise to the canonical form',
      );
      expect(high.r, low.r);
      expect(high.isLowS, isTrue);
    });

    test('hex output is 32-byte zero-padded', () {
      final sig = parseDerSignature(hex(v['derSignature'] as String));
      expect(sig.rHex, v['r']);
      expect(sig.sHex, v['s']);
      expect(sig.rHex.length, 66);
    });

    test('rejects malformed input rather than guessing', () {
      expect(
        () => parseDerSignature(hex('0x')),
        throwsA(isA<PasskeyFormatException>()),
      );
      expect(
        () => parseDerSignature(hex('0x3100')),
        throwsA(isA<PasskeyFormatException>()),
      );
      // Declared length disagrees with actual.
      expect(
        () => parseDerSignature(hex('0x30ff020101020101')),
        throwsA(isA<PasskeyFormatException>()),
      );
      // Trailing bytes after a well-formed signature.
      final good = hex(v['derSignature'] as String);
      final trailing = Uint8List.fromList([...good, 0x00]);
      expect(
        () => parseDerSignature(trailing),
        throwsA(isA<PasskeyFormatException>()),
      );
    });

    test('rejects non-minimal integer encodings', () {
      // 0x00 0x01 for r: padded when it need not be. Tolerating this would let
      // one signature have several valid byte encodings.
      expect(
        () => parseDerSignature(
          hex('0x3008020200010202000 1'.replaceAll(' ', '')),
        ),
        throwsA(isA<PasskeyFormatException>()),
      );
    });
  });

  group('COSE public key parsing', () {
    test('extracts the coordinates the account stores', () {
      final key = parseCoseP256PublicKey(hex(v['coseKey'] as String));
      expect(key.xHex, v['x']);
      expect(key.yHex, v['y']);
    });

    test('rejects a key that is not ES256 P-256', () {
      final cose = hex(v['coseKey'] as String);
      // Flip alg from -7 (0x26) to -8 (0x27): EdDSA, which the precompile
      // cannot verify. Better to refuse at registration than to create an
      // account nobody can ever sign for.
      final i = cose.indexOf(0x26);
      expect(i, greaterThan(0));
      final tampered = Uint8List.fromList(cose)..[i] = 0x27;
      expect(
        () => parseCoseP256PublicKey(tampered),
        throwsA(isA<PasskeyFormatException>()),
      );
    });

    test('rejects truncated input', () {
      final cose = hex(v['coseKey'] as String);
      expect(
        () => parseCoseP256PublicKey(cose.sublist(0, cose.length - 8)),
        throwsA(isA<PasskeyFormatException>()),
      );
    });
  });

  group('attestation object parsing', () {
    test('unwraps CBOR -> authData -> attested data -> COSE key', () {
      final att = parseAttestationObject(hex(v['attestationObject'] as String));
      expect(att.publicKey.xHex, v['x']);
      expect(att.publicKey.yHex, v['y']);
      final credHex =
          att.credentialId
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
      expect('0x$credHex', v['credentialId']);
    });

    test('rejects an attestation with no attested credential data', () {
      // Clear the AT flag (0x40) in authData. Without attested credential data
      // there is no key to register, so this must fail rather than read past.
      final att = Uint8List.fromList(hex(v['attestationObject'] as String));
      final marker = utf8.encode('authData');
      var idx = -1;
      outer:
      for (var i = 0; i + marker.length <= att.length; i++) {
        for (var j = 0; j < marker.length; j++) {
          if (att[i + j] != marker[j]) continue outer;
        }
        idx = i;
        break;
      }
      expect(idx, greaterThan(0));
      // authData byte string head is 0x58 <len> right after the key.
      final flagsAt = idx + marker.length + 2 + 32;
      att[flagsAt] = att[flagsAt] & ~0x40;
      expect(
        () => parseAttestationObject(att),
        throwsA(isA<PasskeyFormatException>()),
      );
    });

    test('rejects truncated attestation', () {
      final att = hex(v['attestationObject'] as String);
      expect(
        () => parseAttestationObject(att.sublist(0, 40)),
        throwsA(isA<PasskeyFormatException>()),
      );
    });
  });

  group('assertion decoding', () {
    test('produces the offsets the contract is told to look at', () {
      final assertion = PasskeyCodec.decodeAssertion(
        credentialId: 'test-credential',
        authenticatorData: hex(v['authenticatorData'] as String),
        clientDataJSON: utf8.encode(v['clientDataJSON'] as String),
        derSignature: hex(v['derSignature'] as String),
      );

      expect(assertion.typeIndex, v['typeIndex']);
      expect(assertion.challengeIndex, v['challengeIndex']);
      expect(assertion.signature.rHex, v['r']);
      expect(assertion.signature.sHex, v['s']);
    });

    test('round-trips base64url without padding', () {
      final raw = hex(v['authenticatorData'] as String);
      expect(b64urlEncode(raw), v['authenticatorDataB64']);
      expect(b64urlDecode(v['authenticatorDataB64'] as String), raw);
      expect(
        utf8.decode(b64urlDecode(v['clientDataJSONB64'] as String)),
        v['clientDataJSON'],
      );
    });
  });

  group('P256 constants', () {
    test('halfN is exactly n / 2', () {
      expect(P256.halfN * BigInt.two, P256.n - BigInt.one);
    });

    test('normalising is idempotent', () {
      final s = big(v['s'] as String);
      expect(P256.normalizeS(P256.normalizeS(s)), P256.normalizeS(s));
    });
  });
}
