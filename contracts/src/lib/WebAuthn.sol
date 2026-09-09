// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base64} from "solady/utils/Base64.sol";

import {P256} from "./P256.sol";

/// @title WebAuthn
/// @notice Verifies a WebAuthn assertion produced by a passkey.
///
/// A WebAuthn assertion is not a signature over the challenge. The authenticator
/// signs
///
///     sha256( authenticatorData || sha256(clientDataJSON) )
///
/// and the challenge appears only inside clientDataJSON, base64url encoded. A
/// contract that verified a bare P-256 signature over the challenge would
/// accept signatures the authenticator never produced for this operation, so
/// the whole structure has to be reconstructed and checked here.
///
/// clientDataJSON is not parsed on-chain — JSON parsing in Solidity is
/// expensive and easy to get wrong. Instead the caller passes the offsets of
/// the two fields we care about and we assert the exact expected bytes sit
/// there. The signature covers the entire JSON, so an attacker cannot alter it;
/// the offsets only tell us where to look.
library WebAuthn {
    struct Auth {
        bytes authenticatorData;
        string clientDataJSON;
        uint256 challengeIndex;
        uint256 typeIndex;
        uint256 r;
        uint256 s;
    }

    /// @dev authenticatorData flag bits (WebAuthn Level 3, §6.1).
    uint8 internal constant FLAG_USER_PRESENT = 0x01;
    uint8 internal constant FLAG_USER_VERIFIED = 0x04;

    /// @dev rpIdHash(32) || flags(1) || signCount(4)
    uint256 internal constant MIN_AUTH_DATA_LENGTH = 37;

    /// @notice Verify an assertion.
    /// @param challenge   What the authenticator was asked to sign (for us, the userOpHash).
    /// @param requireUV   Demand user verification (biometric/PIN), not merely presence.
    /// @param expectedRpIdHash sha256(rpId) the credential must be bound to; bytes32(0) skips.
    /// @param auth        The assertion.
    /// @param x           Credential public key X.
    /// @param y           Credential public key Y.
    function verify(
        bytes memory challenge,
        bool requireUV,
        bytes32 expectedRpIdHash,
        Auth memory auth,
        uint256 x,
        uint256 y
    ) internal view returns (bool) {
        if (auth.authenticatorData.length < MIN_AUTH_DATA_LENGTH) return false;

        // Bind the assertion to our relying party. The authenticator already
        // scopes a credential to its RP, but checking the hash here means a
        // credential registered for another origin cannot be presented to this
        // account even if the client is fully compromised.
        if (expectedRpIdHash != bytes32(0)) {
            bytes32 rpIdHash;
            bytes memory ad = auth.authenticatorData;
            assembly {
                rpIdHash := mload(add(ad, 0x20))
            }
            if (rpIdHash != expectedRpIdHash) return false;
        }

        uint8 flags = uint8(auth.authenticatorData[32]);

        // User presence is mandatory in every case: it is what distinguishes a
        // deliberate action from a silent one.
        if (flags & FLAG_USER_PRESENT != FLAG_USER_PRESENT) return false;
        if (requireUV && flags & FLAG_USER_VERIFIED != FLAG_USER_VERIFIED) return false;

        // "type" must be webauthn.get. Without this, a registration assertion
        // (webauthn.create) could be replayed as an authorisation.
        if (!_matchesAt(auth.clientDataJSON, auth.typeIndex, '"type":"webauthn.get"')) {
            return false;
        }

        // "challenge" must be exactly our challenge, base64url, unpadded.
        string memory expected =
            string.concat('"challenge":"', Base64.encode(challenge, true, true), '"');
        if (!_matchesAt(auth.clientDataJSON, auth.challengeIndex, expected)) return false;

        bytes32 clientDataHash = sha256(bytes(auth.clientDataJSON));
        bytes32 digest = sha256(abi.encodePacked(auth.authenticatorData, clientDataHash));

        // P256.verify rejects high-s. The precompile itself accepts both forms,
        // so the malleability guard has to live here.
        return P256.verify(digest, auth.r, auth.s, x, y);
    }

    /// @dev True if `needle` occurs in `subject` starting exactly at `offset`.
    function _matchesAt(string memory subject, uint256 offset, string memory needle)
        private
        pure
        returns (bool)
    {
        bytes memory s = bytes(subject);
        bytes memory n = bytes(needle);
        // Guard the addition as well as the length: a caller-supplied offset
        // near 2^256 would otherwise wrap and read out of bounds.
        unchecked {
            if (offset > s.length || offset + n.length < offset) return false;
            if (offset + n.length > s.length) return false;
        }
        // Hash the memory range in place rather than slicing: LibString.slice
        // allocates a copy, and this runs on every userOp validation.
        bytes32 got;
        assembly ("memory-safe") {
            got := keccak256(add(add(s, 0x20), offset), mload(n))
        }
        return got == keccak256(n);
    }
}
