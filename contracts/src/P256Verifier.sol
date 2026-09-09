// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title P256Verifier
/// @notice Verifies secp256r1 (P-256) signatures using Monad's precompile.
///
/// P-256 is the curve the iOS Secure Enclave and Android Keystore already use,
/// so a WebAuthn assertion from a phone can be checked on-chain directly. This
/// is what lets an account be controlled by Face ID with no seed phrase.
///
/// The precompile lives at 0x0100 per EIP-7951. Verified present on Monad
/// mainnet (chain 143). Note it has no bytecode — precompiles never do — so
/// `extcodesize` checks against it will wrongly report "not a contract".
library P256Verifier {
    /// @dev EIP-7951 precompile address.
    address internal constant PRECOMPILE = address(0x0100);

    /// @notice Verify a P-256 signature.
    /// @param messageHash 32-byte hash that was signed
    /// @param r Signature r
    /// @param s Signature s
    /// @param x Public key X coordinate
    /// @param y Public key Y coordinate
    /// @return ok True if the signature is valid for the key over the hash.
    function verify(bytes32 messageHash, bytes32 r, bytes32 s, bytes32 x, bytes32 y)
        internal
        view
        returns (bool ok)
    {
        bytes memory input = abi.encodePacked(messageHash, r, s, x, y);

        // staticcall: a failed call and an invalid signature are different
        // things, and conflating them would let a malformed input read as a
        // rejection instead of a bug.
        (bool success, bytes memory out) = PRECOMPILE.staticcall(input);
        if (!success || out.length != 32) {
            return false;
        }
        return abi.decode(out, (uint256)) == 1;
    }
}
