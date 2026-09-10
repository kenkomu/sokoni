import 'dart:convert';
import 'dart:typed_data';

import 'cose.dart';
import 'p256.dart';

/// What a registration produced: the credential, and the key the account will
/// be created around.
class RegisteredPasskey {
  const RegisteredPasskey({
    required this.credentialId,
    required this.publicKey,
  });

  final String credentialId;
  final PublicKeyCoords publicKey;
}

/// A signed assertion, in the pieces `SokoniAccount.validateUserOp` needs.
///
/// The client does not ABI-encode this. The backend builds the userOp, hands
/// the client the userOpHash to sign, and encodes the result — so the phone
/// never needs chain libraries and the encoding lives in exactly one place.
class PasskeyAssertion {
  const PasskeyAssertion({
    required this.credentialId,
    required this.authenticatorData,
    required this.clientDataJSON,
    required this.signature,
  });

  final String credentialId;
  final Uint8List authenticatorData;
  final String clientDataJSON;
  final Signature signature;

  /// Byte offset of `"type":"` within clientDataJSON.
  ///
  /// The contract does not parse JSON; it is told where to look and asserts the
  /// expected bytes are there. Computing the offsets here keeps that cheap
  /// on-chain. The signature covers the whole JSON, so a wrong offset can only
  /// make verification fail, never smuggle content past it.
  int get typeIndex => _indexOf('"type":"');

  /// Byte offset of `"challenge":"` within clientDataJSON.
  int get challengeIndex => _indexOf('"challenge":"');

  int _indexOf(String needle) {
    final haystack = utf8.encode(clientDataJSON);
    final target = utf8.encode(needle);
    outer:
    for (var i = 0; i + target.length <= haystack.length; i++) {
      for (var j = 0; j < target.length; j++) {
        if (haystack[i + j] != target[j]) continue outer;
      }
      return i;
    }
    throw PasskeyFormatException('clientDataJSON has no $needle');
  }

  Map<String, dynamic> toJson() => {
    'credentialId': credentialId,
    'authenticatorData': '0x${_hex(authenticatorData)}',
    'clientDataJSON': clientDataJSON,
    'challengeIndex': challengeIndex,
    'typeIndex': typeIndex,
    'r': signature.rHex,
    's': signature.sHex,
  };

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// Decodes base64url as WebAuthn emits it: no padding.
Uint8List b64urlDecode(String s) {
  final normalized = s.replaceAll('-', '+').replaceAll('_', '/');
  return base64.decode(normalized.padRight((normalized.length + 3) & ~3, '='));
}

String b64urlEncode(Uint8List b) => base64Url.encode(b).replaceAll('=', '');

/// Turns raw platform WebAuthn output into what the account expects.
///
/// Kept free of any plugin type so it can be tested against the same fixture
/// the Solidity tests use — the two sides then provably agree about the same
/// bytes, rather than each being self-consistently wrong.
abstract final class PasskeyCodec {
  /// Registration: COSE_Key bytes to on-chain coordinates.
  static RegisteredPasskey decodeRegistration({
    required String credentialId,
    required Uint8List cosePublicKey,
  }) {
    return RegisteredPasskey(
      credentialId: credentialId,
      publicKey: parseCoseP256PublicKey(cosePublicKey),
    );
  }

  /// Assertion: DER signature to a normalised (r, s).
  static PasskeyAssertion decodeAssertion({
    required String credentialId,
    required Uint8List authenticatorData,
    required Uint8List clientDataJSON,
    required Uint8List derSignature,
  }) {
    return PasskeyAssertion(
      credentialId: credentialId,
      authenticatorData: authenticatorData,
      clientDataJSON: utf8.decode(clientDataJSON),
      // parseDerSignature normalises s at the boundary, so nothing downstream
      // has to remember that the precompile accepts both forms.
      signature: parseDerSignature(derSignature),
    );
  }
}
