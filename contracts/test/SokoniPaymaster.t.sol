// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {SokoniAccount} from "../src/SokoniAccount.sol";
import {SokoniAccountFactory} from "../src/SokoniAccountFactory.sol";
import {SokoniPaymaster} from "../src/SokoniPaymaster.sol";
import {WebAuthn} from "../src/lib/WebAuthn.sol";

/// Records that a sponsored call actually executed.
contract Counter {
    uint256 public value;

    function bump() external {
        ++value;
    }
}

/// Completes the Phase 1 thesis: a phone with no seed phrase **and no MON**
/// drives an ERC-4337 account, with the gas paid by our paymaster.
///
/// `SokoniAccount.t.sol` proves the passkey half by funding the account with 10
/// ether, which quietly assumes the user already holds the chain's native token.
/// A real new user holds nothing. Every test here starts from a zero balance and
/// asserts it is still zero afterwards.
contract SokoniPaymasterTest is Test {
    using stdJson for string;
    using MessageHashUtils for bytes32;

    /// sha256("sokoni.app")
    bytes32 constant RP_ID_HASH =
        0x6b4acac5333939cbe4e8b6d4861c3f455146a279a0cec6fa65b45ed8bc305492;

    /// Gas limits are hardcoded rather than estimated. Monad charges on the gas
    /// *limit*, not the amount used, so a loose estimate is a recurring cost.
    uint128 constant PM_VERIFICATION_GAS = 120_000;
    /// Zero: `_validatePaymasterUserOp` returns an empty context, so the
    /// EntryPoint never calls `postOp`.
    uint128 constant PM_POSTOP_GAS = 0;

    uint48 constant FOREVER = type(uint48).max;
    uint128 constant MAX_COST = 0.5 ether;

    EntryPoint entryPoint;
    SokoniAccountFactory factory;
    SokoniAccount account;
    SokoniPaymaster paymaster;
    Counter counter;

    uint256 signerKey = 0xA11CE;
    address signerAddr;

    address payable beneficiary = payable(address(0xB0B));

    function setUp() public {
        entryPoint = new EntryPoint();
        factory = new SokoniAccountFactory(IEntryPoint(address(entryPoint)));
        counter = new Counter();

        signerAddr = vm.addr(signerKey);
        paymaster = new SokoniPaymaster(IEntryPoint(address(entryPoint)), signerAddr);

        // A paymaster pays from its EntryPoint deposit, and must be staked
        // before bundlers will accept one that reads its own storage during
        // validation — which ours does, to look up the rotatable signer.
        paymaster.deposit{value: 10 ether}();
        paymaster.addStake{value: 1 ether}(1 days);

        SokoniAccount.Passkey[] memory owners = new SokoniAccount.Passkey[](1);
        owners[0] = _pubkey(false);
        account = factory.createAccount(RP_ID_HASH, owners, 0);

        // Deliberately NOT funded. This is the whole point.
        assertEq(address(account).balance, 0, "account must start with no MON");
    }

    // ------------------------------------------------------------------ helpers

    function _pubkey(bool second) internal returns (SokoniAccount.Passkey memory) {
        string[] memory cmd = new string[](second ? 4 : 3);
        cmd[0] = "python3";
        cmd[1] = "script/gen_webauthn_vector.py";
        cmd[2] = "--pubkey";
        if (second) cmd[3] = "second";
        string memory out = string(vm.ffi(cmd));
        return SokoniAccount.Passkey({x: out.readUint(".x"), y: out.readUint(".y")});
    }

    /// Sign `challenge` with the test passkey and pack it as the account expects.
    function _passkeySign(bytes32 challenge) internal returns (bytes memory) {
        string[] memory cmd = new string[](4);
        cmd[0] = "python3";
        cmd[1] = "script/gen_webauthn_vector.py";
        cmd[2] = "--sign";
        cmd[3] = vm.toString(challenge);
        string memory out = string(vm.ffi(cmd));

        WebAuthn.Auth memory auth = WebAuthn.Auth({
            authenticatorData: out.readBytes(".authenticatorData"),
            clientDataJSON: out.readString(".clientDataJSON"),
            challengeIndex: out.readUint(".challengeIndex"),
            typeIndex: out.readUint(".typeIndex"),
            r: out.readUint(".r"),
            s: out.readUint(".s")
        });
        return abi.encode(SokoniAccount.PasskeySignature({ownerIndex: 0, auth: auth}));
    }

    function _userOp(bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op.sender = address(account);
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = callData;
        op.accountGasLimits = bytes32(uint256(600_000) << 128 | uint256(400_000));
        op.preVerificationGas = 100_000;
        op.gasFees = bytes32(uint256(1 gwei) << 128 | uint256(100 gwei));
    }

    function _pack(uint48 validUntil, uint48 validAfter, uint128 maxCost, bytes memory sig)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            address(paymaster),
            PM_VERIFICATION_GAS,
            PM_POSTOP_GAS,
            validUntil,
            validAfter,
            maxCost,
            sig
        );
    }

    /// Fill in `paymasterAndData` with an approval signed by `key`.
    function _sponsor(
        PackedUserOperation memory op,
        uint48 validUntil,
        uint48 validAfter,
        uint128 maxCost,
        uint256 key
    ) internal view returns (bytes memory) {
        // The approval digest reads the paymaster gas limits back out of
        // paymasterAndData, so the field must already be shaped before it can
        // be hashed. A zeroed signature stands in for the one we are computing.
        op.paymasterAndData = _pack(validUntil, validAfter, maxCost, new bytes(65));

        bytes32 digest =
            paymaster.approvalHash(op, validUntil, validAfter, maxCost).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return _pack(validUntil, validAfter, maxCost, abi.encodePacked(r, s, v));
    }

    /// Build, sponsor and passkey-sign a `bump()` call in the right order:
    /// paymasterAndData must be final before the userOpHash is taken, because
    /// the hash covers it.
    function _sponsoredBump(uint48 validUntil, uint48 validAfter, uint128 maxCost, uint256 key)
        internal
        returns (PackedUserOperation memory op)
    {
        op = _userOp(
            abi.encodeCall(
                SokoniAccount.execute, (address(counter), 0, abi.encodeCall(Counter.bump, ()))
            )
        );
        op.paymasterAndData = _sponsor(op, validUntil, validAfter, maxCost, key);
        op.signature = _passkeySign(entryPoint.getUserOpHash(op));
    }

    function _handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }

    // -------------------------------------------------------------------- tests

    /// The headline: no seed phrase, no MON, and the transaction still lands.
    function test_SponsorsAPasskeyUserOpForAnAccountWithNoMon() public {
        PackedUserOperation memory op = _sponsoredBump(FOREVER, 0, MAX_COST, signerKey);

        uint256 depositBefore = paymaster.getDeposit();
        _handle(op);

        assertEq(counter.value(), 1, "sponsored call must execute");
        assertEq(address(account).balance, 0, "account must never need MON");
        assertLt(paymaster.getDeposit(), depositBefore, "paymaster must have paid");
    }

    function test_RejectsApprovalSignedByAnotherKey() public {
        PackedUserOperation memory op = _sponsoredBump(FOREVER, 0, MAX_COST, 0xBADBAD);

        vm.expectRevert();
        _handle(op);
    }

    /// The approval covers callData, so swapping the call after signing must fail.
    function test_RejectsApprovalForADifferentOperation() public {
        PackedUserOperation memory op = _sponsoredBump(FOREVER, 0, MAX_COST, signerKey);
        // Re-point the call at a different target, then re-sign only the passkey
        // half — the paymaster approval no longer matches.
        op.callData = abi.encodeCall(SokoniAccount.execute, (address(0xDEAD), 0, ""));
        op.signature = _passkeySign(entryPoint.getUserOpHash(op));

        vm.expectRevert();
        _handle(op);
    }

    /// The explicit ceiling, and the reason it exists: the EntryPoint's own
    /// prefund arithmetic must stay under what the backend committed to.
    function test_RejectsWhenRequiredPrefundExceedsMaxCost() public {
        PackedUserOperation memory op = _sponsoredBump(FOREVER, 0, 1 wei, signerKey);

        vm.expectRevert();
        _handle(op);
    }

    /// A truncated or oversized approval must read as invalid, never revert —
    /// a revert in the validation phase takes down the whole bundle.
    function test_MalformedPaymasterDataIsRejectedNotReverted() public {
        PackedUserOperation memory op = _sponsoredBump(FOREVER, 0, MAX_COST, signerKey);
        // Chop the signature short: still long enough to hold the gas limits the
        // EntryPoint parses, but not a valid approval.
        op.paymasterAndData = _pack(FOREVER, 0, MAX_COST, new bytes(31));
        op.signature = _passkeySign(entryPoint.getUserOpHash(op));

        vm.expectRevert();
        _handle(op);

        assertEq(counter.value(), 0, "nothing may execute on a malformed approval");
    }

    function test_ExpiredApprovalIsRejected() public {
        vm.warp(10_000);
        PackedUserOperation memory op = _sponsoredBump(uint48(5_000), 0, MAX_COST, signerKey);

        vm.expectRevert();
        _handle(op);
    }

    function test_ApprovalNotYetValidIsRejected() public {
        vm.warp(1_000);
        PackedUserOperation memory op = _sponsoredBump(FOREVER, uint48(5_000), MAX_COST, signerKey);

        vm.expectRevert();
        _handle(op);
    }

    /// Containment: rotating the key must invalidate approvals from the old one
    /// without moving the deposit or re-staking.
    function test_RotatingTheSignerInvalidatesTheOldKey() public {
        uint256 nextKey = 0xB0B5;
        paymaster.rotateSigner(vm.addr(nextKey));

        PackedUserOperation memory stale = _sponsoredBump(FOREVER, 0, MAX_COST, signerKey);
        vm.expectRevert();
        _handle(stale);

        PackedUserOperation memory fresh = _sponsoredBump(FOREVER, 0, MAX_COST, nextKey);
        _handle(fresh);
        assertEq(counter.value(), 1, "the rotated key must work immediately");
    }

    function test_OnlyOwnerCanRotateTheSigner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        paymaster.rotateSigner(address(0xCAFE));
    }

    function test_SignerCannotBeZero() public {
        vm.expectRevert(SokoniPaymaster.SignerIsZero.selector);
        paymaster.rotateSigner(address(0));

        vm.expectRevert(SokoniPaymaster.SignerIsZero.selector);
        new SokoniPaymaster(IEntryPoint(address(entryPoint)), address(0));
    }

    /// An approval is bound to (sender, nonce), so consuming it once is enough:
    /// the EntryPoint will not accept that nonce again.
    function test_ApprovalCannotBeReplayed() public {
        PackedUserOperation memory op = _sponsoredBump(FOREVER, 0, MAX_COST, signerKey);
        _handle(op);
        assertEq(counter.value(), 1);

        // Same bytes, second time.
        vm.expectRevert();
        _handle(op);
        assertEq(counter.value(), 1, "a spent approval must not execute twice");
    }

    /// The paymaster must not sponsor an account whose passkey signature is bad,
    /// even when the sponsorship itself is perfectly valid.
    function test_ValidSponsorshipDoesNotRescueABadPasskeySignature() public {
        PackedUserOperation memory op = _userOp(
            abi.encodeCall(
                SokoniAccount.execute, (address(counter), 0, abi.encodeCall(Counter.bump, ()))
            )
        );
        op.paymasterAndData = _sponsor(op, FOREVER, 0, MAX_COST, signerKey);
        op.signature = _passkeySign(keccak256("a different operation entirely"));

        vm.expectRevert();
        _handle(op);
    }

    function test_OnlyEntryPointCanCallValidate() public {
        PackedUserOperation memory op = _sponsoredBump(FOREVER, 0, MAX_COST, signerKey);

        vm.expectRevert(bytes("Sender not EntryPoint"));
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
    }

    function test_OwnerCanWithdrawDeposit() public {
        address payable to = payable(address(0xF00D));
        uint256 before = paymaster.getDeposit();

        paymaster.withdrawTo(to, 1 ether);

        assertEq(to.balance, 1 ether);
        assertEq(paymaster.getDeposit(), before - 1 ether);
    }

    function test_OnlyOwnerCanWithdrawDeposit() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        paymaster.withdrawTo(payable(address(0xBEEF)), 1 ether);
    }

    /// Bad offsets and lengths are attacker-reachable. None may revert.
    function testFuzz_ArbitraryPaymasterDataNeverReverts(bytes calldata junk) public {
        vm.assume(junk.length >= 52 && junk.length <= 400);

        PackedUserOperation memory op = _userOp(
            abi.encodeCall(
                SokoniAccount.execute, (address(counter), 0, abi.encodeCall(Counter.bump, ()))
            )
        );
        // Keep the paymaster address and gas limits well-formed so the EntryPoint
        // routes to us at all; everything after byte 52 is the fuzzer's.
        op.paymasterAndData =
            abi.encodePacked(address(paymaster), PM_VERIFICATION_GAS, PM_POSTOP_GAS, junk[52:]);

        (, uint256 validationData) = _callValidate(op);
        assertEq(validationData & 1, 1, "junk must fail closed, not authorise");
    }

    /// Calls validation the way the EntryPoint does, so a revert surfaces as a
    /// test failure rather than being swallowed by handleOps.
    function _callValidate(PackedUserOperation memory op)
        internal
        returns (bytes memory context, uint256 validationData)
    {
        vm.prank(address(entryPoint));
        return paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
    }
}
