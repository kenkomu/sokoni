// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title P256
/// @notice secp256r1 signature verification via Monad's precompile.
///
/// P-256 is the curve the iOS Secure Enclave and Android Keystore already use,
/// so a signature produced by Face ID can be checked on-chain directly. That is
/// what lets an account be controlled by a passkey with no seed phrase.
///
/// The precompile is at 0x0100 per EIP-7951 (which supersedes RIP-7212 at the
/// same address with an identical interface). It takes exactly 160 bytes and
/// returns 32 bytes of 1 for a valid signature, or EMPTY bytes for an invalid
/// one — not a zero word. Gas cost is 6900.
///
/// Precompiles carry no bytecode, so `extcodesize(0x100)` is 0. Any "is this a
/// contract" guard will wrongly conclude it is absent.
library P256 {
    /// @dev EIP-7951 precompile.
    address internal constant VERIFIER = address(0x0100);

    /// @dev Order of the P-256 base point.
    uint256 internal constant N =
        0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    /// @dev N/2. Signatures with s above this are malleable; see `verify`.
    uint256 internal constant HALF_N =
        0x7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8;

    /// @notice Verify a P-256 signature, rejecting malleable (high-s) forms.
    ///
    /// @dev Both (r, s) and (r, N - s) verify for the same message, and the
    /// precompile accepts both — confirmed against Monad mainnet, where a
    /// high-s variant of a valid signature also returned 1. Accepting both
    /// would mean one authorisation has two distinct valid encodings, so a
    /// signature could be mutated and still pass any check keyed on its bytes.
    /// We require the canonical low-s form; clients normalise before
    /// submitting, which is what WebAuthn libraries do by convention.
    function verify(bytes32 hash, uint256 r, uint256 s, uint256 x, uint256 y)
        internal
        view
        returns (bool)
    {
        if (r == 0 || r >= N || s == 0 || s > HALF_N) return false;
        return verifyMalleable(hash, r, s, x, y);
    }

    /// @notice Raw precompile call, accepting high-s.
    /// @dev Exposed for tests and for callers that have already normalised.
    /// Prefer `verify`.
    function verifyMalleable(bytes32 hash, uint256 r, uint256 s, uint256 x, uint256 y)
        internal
        view
        returns (bool)
    {
        (bool ok, bytes memory out) = VERIFIER.staticcall(abi.encodePacked(hash, r, s, x, y));
        // An invalid signature returns empty bytes, so length must be checked
        // before decoding — abi.decode on empty data reverts.
        return ok && out.length == 32 && abi.decode(out, (uint256)) == 1;
    }

    /// @notice Normalise s into the canonical low half of the curve order.
    function normalize(uint256 s) internal pure returns (uint256) {
        return s > HALF_N ? N - s : s;
    }
}
