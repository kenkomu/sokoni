// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {P256Verifier} from "../src/P256Verifier.sol";

contract P256VerifierTest is Test {
    /// A garbage signature must be rejected, not revert. The distinction
    /// matters: onboarding must fail closed and legibly, never blow up.
    function test_RejectsGarbage() public view {
        bool ok = P256Verifier.verify(
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            bytes32(uint256(4)),
            bytes32(uint256(5))
        );
        assertFalse(ok, "garbage signature must not verify");
    }

    /// Zero inputs are the degenerate case an attacker reaches for first.
    function test_RejectsZeroes() public view {
        bool ok = P256Verifier.verify(bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0));
        assertFalse(ok, "zero signature must not verify");
    }

    // TODO(phase-1): assert a KNOWN-GOOD WebAuthn assertion verifies. That is
    // the test that actually proves the product thesis, and it needs a real
    // vector captured from a device. Run it forked against Monad, because the
    // precompile does not exist on a bare local EVM.
}
