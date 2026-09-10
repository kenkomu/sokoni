import 'dart:typed_data';

import 'p256.dart';

/// The P-256 public key of a passkey credential.
///
/// These two coordinates are the account's owner on-chain — `SokoniAccount`
/// stores exactly this pair and Monad's precompile verifies against it.
class PublicKeyCoords {
  const PublicKeyCoords(this.x, this.y);

  final BigInt x;
  final BigInt y;

  String get xHex => '0x${x.toRadixString(16).padLeft(64, '0')}';
  String get yHex => '0x${y.toRadixString(16).padLeft(64, '0')}';

  @override
  String toString() => 'PublicKeyCoords($xHex, $yHex)';
}

/// Extracts (x, y) from the COSE_Key a WebAuthn registration returns.
///
/// Registration hands back a CBOR-encoded COSE_Key, not raw coordinates:
///
///     {1: 2 (kty EC2), 3: -7 (alg ES256), -1: 1 (crv P-256), -2: x, -3: y}
///
/// Only that shape is accepted. A credential using another curve or algorithm
/// is not something this account can ever verify, so it is rejected at
/// registration rather than producing an account nobody can sign for.
///
/// This is a deliberately narrow CBOR reader, not a general decoder: it
/// understands only the major types a COSE EC2 key uses. Anything else is an
/// error, which is the right posture for parsing attacker-reachable input.
PublicKeyCoords parseCoseP256PublicKey(Uint8List cose) {
  var i = 0;

  int readByte(String what) {
    if (i >= cose.length) {
      throw PasskeyFormatException('truncated before $what');
    }
    return cose[i++];
  }

  /// Reads one CBOR head, returning (majorType, argument).
  (int, int) readHead(String what) {
    final b = readByte(what);
    final major = b >> 5;
    final minor = b & 0x1f;
    if (minor < 24) return (major, minor);
    if (minor == 24) return (major, readByte('$what argument'));
    if (minor == 25) {
      final hi = readByte('$what argument');
      return (major, (hi << 8) | readByte('$what argument'));
    }
    throw PasskeyFormatException('unsupported CBOR length form in $what');
  }

  final (mapMajor, pairCount) = readHead('COSE map');
  if (mapMajor != 5) {
    throw const PasskeyFormatException('COSE key is not a CBOR map');
  }

  int? kty;
  int? alg;
  int? crv;
  Uint8List? x;
  Uint8List? y;

  for (var pair = 0; pair < pairCount; pair++) {
    final (keyMajor, keyArg) = readHead('COSE label');
    // Labels are small ints: major 0 is unsigned, major 1 is negative (-1-arg).
    final int label;
    if (keyMajor == 0) {
      label = keyArg;
    } else if (keyMajor == 1) {
      label = -1 - keyArg;
    } else {
      throw const PasskeyFormatException('COSE label is not an integer');
    }

    final (valMajor, valArg) = readHead('COSE value');
    switch (valMajor) {
      case 0: // unsigned
        if (label == 1) kty = valArg;
        if (label == -1) crv = valArg;
      case 1: // negative
        if (label == 3) alg = -1 - valArg;
      case 2: // byte string
        if (i + valArg > cose.length) {
          throw const PasskeyFormatException(
            'COSE byte string runs past the end',
          );
        }
        final bytes = cose.sublist(i, i + valArg);
        i += valArg;
        if (label == -2) x = bytes;
        if (label == -3) y = bytes;
      default:
        throw PasskeyFormatException(
          'unexpected CBOR major type $valMajor in COSE key',
        );
    }
  }

  if (kty != 2) throw PasskeyFormatException('kty $kty is not EC2');
  if (alg != -7) throw PasskeyFormatException('alg $alg is not ES256');
  if (crv != 1) throw PasskeyFormatException('crv $crv is not P-256');
  if (x == null || y == null) {
    throw const PasskeyFormatException('COSE key is missing a coordinate');
  }
  // Coordinates are fixed-width for P-256. A short one would silently become a
  // different key once left-padded.
  if (x.length != 32 || y.length != 32) {
    throw PasskeyFormatException(
      'coordinates must be 32 bytes, got ${x.length}/${y.length}',
    );
  }

  return PublicKeyCoords(_toBigInt(x), _toBigInt(y));
}

BigInt _toBigInt(Uint8List bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}
