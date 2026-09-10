import 'dart:typed_data';

/// secp256r1 constants and the signature handling the account contract expects.
abstract final class P256 {
  /// Order of the P-256 base point.
  static final BigInt n = BigInt.parse(
    'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
    radix: 16,
  );

  /// n / 2. Signatures above this are the malleable form.
  static final BigInt halfN = n >> 1;

  /// Normalise `s` into the canonical low half of the curve order.
  ///
  /// This is not optional. Monad's P-256 precompile accepts BOTH `(r, s)` and
  /// `(r, n - s)` — confirmed against mainnet — so `SokoniAccount` rejects the
  /// high form to keep one authorisation from having two valid encodings.
  /// Authenticators are free to return either, so the client must normalise
  /// before submitting or roughly half of all signatures would be rejected.
  static BigInt normalizeS(BigInt s) => s > halfN ? n - s : s;
}

/// An ECDSA signature as the account contract wants it.
class Signature {
  const Signature(this.r, this.s);

  final BigInt r;
  final BigInt s;

  bool get isLowS => s <= P256.halfN;

  /// 0x-prefixed, 32-byte zero-padded, ready for the wire.
  String get rHex => _hex32(r);
  String get sHex => _hex32(s);

  static String _hex32(BigInt v) => '0x${v.toRadixString(16).padLeft(64, '0')}';

  @override
  String toString() => 'Signature($rHex, $sHex)';
}

/// Thrown when authenticator output cannot be parsed.
class PasskeyFormatException implements Exception {
  const PasskeyFormatException(this.message);
  final String message;
  @override
  String toString() => 'PasskeyFormatException: $message';
}

/// Parses the DER-encoded ECDSA signature a WebAuthn authenticator returns.
///
/// Platform APIs hand back DER, never raw `r||s`:
///
///     30 <len> 02 <lenR> <R> 02 <lenS> <S>
///
/// Each integer is minimal big-endian two's complement, so a value whose top
/// bit is set carries a leading 0x00. Assuming a fixed 32-byte width is the
/// classic way to get this wrong, and it fails on roughly half of signatures.
Signature parseDerSignature(Uint8List der) {
  var i = 0;

  int next(String what) {
    if (i >= der.length) throw PasskeyFormatException('truncated before $what');
    return der[i++];
  }

  if (next('sequence tag') != 0x30) {
    throw const PasskeyFormatException('not a DER sequence');
  }

  final seqLen = next('sequence length');
  // Short-form lengths only: an ECDSA P-256 signature is always < 128 bytes,
  // so a long-form length here means the input is not what we think it is.
  if (seqLen & 0x80 != 0) {
    throw const PasskeyFormatException(
      'long-form length is not a P-256 signature',
    );
  }
  if (seqLen != der.length - 2) {
    throw PasskeyFormatException(
      'declared length $seqLen != actual ${der.length - 2}',
    );
  }

  BigInt readInt(String label) {
    if (next('$label tag') != 0x02) {
      throw PasskeyFormatException('$label is not a DER integer');
    }
    final len = next('$label length');
    if (len == 0) throw PasskeyFormatException('$label is empty');
    if (len & 0x80 != 0) {
      throw PasskeyFormatException('$label has a long-form length');
    }
    if (i + len > der.length) {
      throw PasskeyFormatException('$label runs past the end');
    }
    final bytes = der.sublist(i, i + len);
    i += len;

    // Reject non-minimal encodings rather than silently accepting them: a
    // parser that tolerates padding accepts several byte strings for the same
    // signature, which is malleability by another route.
    if (bytes[0] & 0x80 != 0) {
      throw PasskeyFormatException('$label is negative');
    }
    if (bytes.length > 1 && bytes[0] == 0x00 && bytes[1] & 0x80 == 0) {
      throw PasskeyFormatException('$label is not minimally encoded');
    }

    var v = BigInt.zero;
    for (final b in bytes) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }

  final r = readInt('r');
  final s = readInt('s');

  if (i != der.length) {
    throw const PasskeyFormatException('trailing bytes after signature');
  }
  if (r == BigInt.zero || r >= P256.n) {
    throw const PasskeyFormatException('r out of range');
  }
  if (s == BigInt.zero || s >= P256.n) {
    throw const PasskeyFormatException('s out of range');
  }

  // Normalise here, at the boundary, so nothing downstream has to remember to.
  return Signature(r, P256.normalizeS(s));
}
