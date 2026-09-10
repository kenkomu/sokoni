import 'dart:math';
import 'dart:typed_data';

import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

import 'cose.dart';
import 'p256.dart';
import 'passkey_service.dart';

/// Talks to the platform's WebAuthn implementation.
///
/// On Android this is Credential Manager, on iOS the AuthenticationServices
/// framework. The private key is created inside the Secure Enclave or Android
/// Keystore and never leaves it — there is nothing to export, back up, or
/// phish, which is the entire point.
class PasskeyAuthenticatorService {
  PasskeyAuthenticatorService({
    required this.relyingPartyId,
    required this.relyingPartyName,
    PasskeyAuthenticator? authenticator,
  }) : _auth = authenticator ?? PasskeyAuthenticator();

  final PasskeyAuthenticator _auth;

  /// The domain the credential is bound to. The platform refuses to create or
  /// use a credential unless this domain serves a Digital Asset Links file
  /// naming this app's signing certificate — which is what stops another app
  /// from silently using our credentials.
  final String relyingPartyId;
  final String relyingPartyName;

  /// Create a passkey and return the key the account will be owned by.
  Future<RegisteredPasskey> register({
    required String userId,
    required String userName,
    required String displayName,
  }) async {
    final response = await _auth.register(
      RegisterRequestType(
        challenge: b64urlEncode(_randomBytes(32)),
        relyingParty: RelyingPartyType(
          id: relyingPartyId,
          name: relyingPartyName,
        ),
        user: UserType(id: userId, name: userName, displayName: displayName),
        excludeCredentials: const [],
        authSelectionType: AuthenticatorSelectionType(
          // A platform authenticator, so the key stays on this device in
          // hardware rather than on a roaming security key.
          authenticatorAttachment: 'platform',
          requireResidentKey: true,
          residentKey: 'required',
          // The account moves money: demand the biometric or PIN, not merely a
          // tap. This mirrors requireUV in SokoniAccount.
          userVerification: 'required',
        ),
        // ES256 only. It is the one algorithm Monad's precompile can verify, so
        // accepting anything else would create an account nobody can sign for.
        pubKeyCredParams: [PubKeyCredParamType(type: 'public-key', alg: -7)],
      ),
    );

    final attested = parseAttestationObject(
      b64urlDecode(response.attestationObject),
    );
    return RegisteredPasskey(
      credentialId: response.rawId,
      publicKey: attested.publicKey,
    );
  }

  /// Sign a challenge — in production, the userOpHash the backend handed us.
  Future<PasskeyAssertion> sign({
    required Uint8List challenge,
    List<String> allowCredentialIds = const [],
  }) async {
    final response = await _auth.authenticate(
      AuthenticateRequestType(
        relyingPartyId: relyingPartyId,
        challenge: b64urlEncode(challenge),
        mediation: MediationType.Optional,
        preferImmediatelyAvailableCredentials: true,
        userVerification: 'required',
        allowCredentials: [
          for (final id in allowCredentialIds)
            CredentialType(type: 'public-key', id: id, transports: const []),
        ],
      ),
    );

    return PasskeyCodec.decodeAssertion(
      credentialId: response.rawId,
      authenticatorData: b64urlDecode(response.authenticatorData),
      clientDataJSON: b64urlDecode(response.clientDataJSON),
      derSignature: b64urlDecode(response.signature),
    );
  }

  /// Whether this device can do passkeys at all.
  Future<bool> isAvailable() async {
    try {
      // ignore: deprecated_member_use
      return await _auth.canAuthenticate();
    } catch (_) {
      return false;
    }
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }
}

/// Turns plugin and parsing failures into something worth showing a person.
///
/// "PlatformException(failed, null, null)" tells the user nothing they can act
/// on. Each of these names the actual situation and, where there is one, the
/// way out.
String describePasskeyFailure(Object error) {
  final text = error.toString();
  if (text.contains('cancelled') || text.contains('Cancelled')) {
    return 'Cancelled. Nothing was created.';
  }
  if (text.contains('exclude-credentials-match')) {
    return 'This device already has a passkey for Sokoni. Sign in instead.';
  }
  if (text.contains('android-unsupported') || text.contains('not supported')) {
    return 'This device does not support passkeys. Android 9 or later with '
        'Google Play services is required.';
  }
  if (text.contains('no-credentials') || text.contains('No credentials')) {
    return 'No passkey found on this device. Create one first.';
  }
  if (text.contains('DOMException') || text.contains('SecurityError')) {
    return 'This app is not yet linked to $_rpHint. Check the Digital Asset '
        'Links setup.';
  }
  if (error is PasskeyFormatException) {
    return 'The authenticator returned something unexpected: ${error.message}';
  }
  return 'Passkey failed: $text';
}

const _rpHint = 'the relying party domain';
