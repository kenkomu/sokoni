// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SimpleAccount} from "account-abstraction/samples/SimpleAccount.sol";
import {SimpleAccountFactory} from "account-abstraction/samples/SimpleAccountFactory.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {SokoniPaymaster} from "../src/SokoniPaymaster.sol";

/// Records that a sponsored call actually executed.
contract Counter {
    uint256 public value;

    function bump() external {
        ++value;
    }
}

/// Proves Option 2 end-to-end: a plain ECDSA key (standing in for a
/// Mera-derived one — Mera itself just hands back 32 bytes of key material,
/// see mobile/lib/data/mera/ for what turns that into this key) owns a
/// `SimpleAccount`, and the *existing, unmodified* `SokoniPaymaster` sponsors
/// it with zero changes on either side.
///
/// Deliberately mirrors SokoniPaymaster.t.sol's structure and assertions —
/// same paymaster, same sponsorship guarantees, only the account and its
/// signature scheme differ. Where that file proves "no seed phrase, no MON,
/// with a passkey," this proves the same holds with a Mera-derived key.
contract MeraAccountTest is Test {
    using MessageHashUtils for bytes32;

    uint128 constant PM_VERIFICATION_GAS = 120_000;
    uint128 constant PM_POSTOP_GAS = 0;
    uint48 constant FOREVER = type(uint48).max;
    uint128 constant MAX_COST = 0.5 ether;

    EntryPoint entryPoint;
    SimpleAccountFactory factory;
    SimpleAccount account;
    SokoniPaymaster paymaster;
    Counter counter;

    uint256 signerKey = 0xA11CE;
    address signerAddr;

    // Stands in for a Mera-derived key in this contract test — the real
    // mobile client derives this from the passkey's PRF output instead of
    // holding a hardcoded value. What the account and paymaster see is
    // identical either way: an address and an ECDSA signature.
    uint256 ownerKey = 0xF00D;
    address ownerAddr;

    address payable beneficiary = payable(address(0xB0B));

    function setUp() public {
        entryPoint = new EntryPoint();
        factory = new SimpleAccountFactory(IEntryPoint(address(entryPoint)));
        counter = new Counter();

        signerAddr = vm.addr(signerKey);
        paymaster = new SokoniPaymaster(IEntryPoint(address(entryPoint)), signerAddr);
        paymaster.deposit{value: 10 ether}();
        paymaster.addStake{value: 1 ether}(1 days);

        ownerAddr = vm.addr(ownerKey);
        account = factory.createAccount(ownerAddr, 0);

        // Deliberately NOT funded. This is the whole point.
        assertEq(address(account).balance, 0, "account must start with no MON");
    }

    // ------------------------------------------------------------------ helpers

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
            address(paymaster), PM_VERIFICATION_GAS, PM_POSTOP_GAS, validUntil, validAfter, maxCost, sig
        );
    }

    function _sponsor(
        PackedUserOperation memory op,
        uint48 validUntil,
        uint48 validAfter,
        uint128 maxCost,
        uint256 key
    ) internal view returns (bytes memory) {
        op.paymasterAndData = _pack(validUntil, validAfter, maxCost, new bytes(65));
        bytes32 digest =
            paymaster.approvalHash(op, validUntil, validAfter, maxCost).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return _pack(validUntil, validAfter, maxCost, abi.encodePacked(r, s, v));
    }

    /// SimpleAccount signs the EIP-191-wrapped userOpHash — plain ECDSA, the
    /// same shape any wallet library (including web3dart on the client)
    /// already produces. No WebAuthn assertion structure involved.
    function _ownerSign(PackedUserOperation memory op) internal view returns (bytes memory) {
        bytes32 hash = entryPoint.getUserOpHash(op).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, hash);
        return abi.encodePacked(r, s, v);
    }

    function _sponsoredBump(uint48 validUntil, uint48 validAfter, uint128 maxCost, uint256 key)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _userOp(
            abi.encodeCall(SimpleAccount.execute, (address(counter), 0, abi.encodeCall(Counter.bump, ())))
        );
        op.paymasterAndData = _sponsor(op, validUntil, validAfter, maxCost, key);
        op.signature = _ownerSign(op);
    }

    function _handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }

    // -------------------------------------------------------------------- tests

    function test_CounterfactualAddressMatchesWhatCreateAccountProduces() public view {
        address predicted = factory.getAddress(ownerAddr, 0);
        assertEq(predicted, address(account), "getAddress must match the deployed account");
    }

    /// The headline, same as SokoniPaymaster.t.sol's: no seed phrase in the
    /// user-facing sense (the key comes from a passkey via Mera, never
    /// typed/written down), no MON, and the transaction still lands.
    function test_SponsorsAMeraOwnerUserOpForAnAccountWithNoMon() public {
        PackedUserOperation memory op = _sponsoredBump(FOREVER, 0, MAX_COST, signerKey);

        uint256 depositBefore = paymaster.getDeposit();
        _handle(op);

        assertEq(counter.value(), 1, "sponsored call must execute");
        assertEq(address(account).balance, 0, "account must never need MON");
        assertLt(paymaster.getDeposit(), depositBefore, "paymaster must have paid");
    }

    function test_RejectsAUserOpSignedByTheWrongKey() public {
        PackedUserOperation memory op = _userOp(
            abi.encodeCall(SimpleAccount.execute, (address(counter), 0, abi.encodeCall(Counter.bump, ())))
        );
        op.paymasterAndData = _sponsor(op, FOREVER, 0, MAX_COST, signerKey);

        bytes32 hash = entryPoint.getUserOpHash(op).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBAD, hash);
        op.signature = abi.encodePacked(r, s, v);

        vm.expectRevert();
        _handle(op);
    }

    /// Direct execution by the owner (no EntryPoint) also works — SimpleAccount
    /// allows this, and it is how a non-sponsored fallback path would call in
    /// if the paymaster were ever unavailable.
    function test_OwnerCanExecuteDirectlyWithoutTheEntryPoint() public {
        vm.prank(ownerAddr);
        account.execute(address(counter), 0, abi.encodeCall(Counter.bump, ()));
        assertEq(counter.value(), 1);
    }
}
