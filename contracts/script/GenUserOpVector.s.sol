// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {SokoniPaymaster} from "../src/SokoniPaymaster.sol";

/// Emits the golden vector that pins the userOp hashes across Solidity and Go.
///
/// The backend builds every userOp and hands the phone a userOpHash to sign, so
/// if Go's hash disagrees with the EntryPoint's by one byte, the passkey signs
/// something the account will never accept — and the failure appears as a bare
/// "AA24 signature error" from a bundler, with nothing pointing at the encoding.
/// The same reasoning that made the WebAuthn fixture shared applies here: two
/// implementations of one hash must be checked against each other, not each
/// against itself.
///
/// Run with `make userop-vector`; CI regenerates and diffs.
contract GenUserOpVector is Script {
    /// A fixed 65-byte stand-in, so both sides hash identical bytes. The
    /// approval digest excludes the signature, but the userOpHash covers the
    /// whole of paymasterAndData, so it has to be pinned too.
    function _dummySig() internal pure returns (bytes memory out) {
        out = new bytes(65);
        for (uint256 i; i < 65; ++i) {
            out[i] = 0x01;
        }
    }

    function run() external {
        // Pin the chain id rather than inheriting Foundry's default. The digest
        // commits to it, so leaving it to the toolchain would make this fixture
        // drift whenever the local and CI Foundry versions differ — a diff
        // failure that says nothing about the code. 10143 is Monad testnet,
        // where Phase 1 actually runs (ADR 8).
        vm.chainId(10143);

        EntryPoint entryPoint = new EntryPoint();
        SokoniPaymaster paymaster =
            new SokoniPaymaster(IEntryPoint(address(entryPoint)), address(0xA11CE));

        uint128 pmVerificationGas = 120_000;
        uint128 pmPostOpGas = 0;
        uint48 validUntil = 1_800_000_000;
        uint48 validAfter = 1_700_000_000;
        uint128 maxCost = 0.5 ether;

        PackedUserOperation memory op;
        op.sender = address(0x00000000000000000000000000000000000000A1);
        op.nonce = 7;
        // Non-empty on purpose: exercises the factory/factoryData split that the
        // JSON-RPC form uses and the packed form does not.
        op.initCode =
            abi.encodePacked(address(0x00000000000000000000000000000000000000F2), hex"deadbeef");
        op.callData = hex"b61d27f6000000000000000000000000000000000000000000000000000000000000c0de";
        op.accountGasLimits = bytes32(uint256(600_000) << 128 | uint256(400_000));
        op.preVerificationGas = 100_000;
        op.gasFees = bytes32(uint256(1 gwei) << 128 | uint256(100 gwei));
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            pmVerificationGas,
            pmPostOpGas,
            validUntil,
            validAfter,
            maxCost,
            _dummySig()
        );
        op.signature = hex"";

        string memory k = "vector";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "entryPoint", address(entryPoint));
        vm.serializeAddress(k, "paymaster", address(paymaster));
        vm.serializeAddress(k, "sender", op.sender);
        vm.serializeUint(k, "nonce", op.nonce);
        vm.serializeBytes(k, "initCode", op.initCode);
        vm.serializeBytes(k, "callData", op.callData);
        vm.serializeUint(k, "verificationGasLimit", 600_000);
        vm.serializeUint(k, "callGasLimit", 400_000);
        vm.serializeUint(k, "preVerificationGas", op.preVerificationGas);
        vm.serializeUint(k, "maxPriorityFeePerGas", 1 gwei);
        vm.serializeUint(k, "maxFeePerGas", 100 gwei);
        vm.serializeUint(k, "paymasterVerificationGasLimit", pmVerificationGas);
        vm.serializeUint(k, "paymasterPostOpGasLimit", pmPostOpGas);
        vm.serializeUint(k, "validUntil", validUntil);
        vm.serializeUint(k, "validAfter", validAfter);
        vm.serializeUint(k, "maxCost", maxCost);
        vm.serializeBytes(k, "paymasterAndData", op.paymasterAndData);
        vm.serializeBytes32(k, "userOpHash", entryPoint.getUserOpHash(op));
        string memory out = vm.serializeBytes32(
            k, "approvalHash", paymaster.approvalHash(op, validUntil, validAfter, maxCost)
        );

        vm.writeJson(out, "./test/fixtures/userop_vector.json");
    }
}
