// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {SokoniAccount} from "../src/SokoniAccount.sol";
import {SokoniAccountFactory} from "../src/SokoniAccountFactory.sol";
import {SokoniPaymaster} from "../src/SokoniPaymaster.sol";
import {WebAuthn} from "../src/lib/WebAuthn.sol";

/// Emits the golden vector that pins userOp hashing and ABI encoding across
/// Solidity and Go.
///
/// The backend builds every userOp, encodes every call it makes, and hands the
/// phone a userOpHash to sign. Each of those is a place where two
/// implementations must agree byte for byte, and where disagreement surfaces
/// only as an opaque rejection from a bundler: `AA24 signature error` if the
/// hash is wrong, `AA23 reverted` if the signature encoding is. Neither error
/// mentions encoding.
///
/// The same reasoning that made the WebAuthn fixture shared applies here — two
/// implementations of one encoding must be checked against each other, not each
/// against itself.
///
/// Run with `make userop-vector`; CI regenerates and diffs.
contract GenUserOpVector is Script {
    using stdJson for string;

    /// The frozen WebAuthn assertion that WebAuthn.t.sol, the Dart tests and
    /// the Go tests all assert against — read from its fixture, not copied in.
    /// Pinning the signature encoding over that one assertion checks it on the
    /// same bytes everything else agrees on, and keeps 64-hex-digit literals out
    /// of source, where the security workflow would rightly take them for keys.
    string constant WEBAUTHN_FIXTURE = "./test/fixtures/webauthn_vector.json";

    bytes32 constant RP_ID_HASH = sha256(bytes("sokoni.app"));

    /// Deliberately not 0, so an implementation that drops the field entirely
    /// cannot pass by accident.
    uint256 constant OWNER_INDEX = 1;

    uint256 constant SALT = 42;

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
        SokoniAccountFactory factory = new SokoniAccountFactory(IEntryPoint(address(entryPoint)));

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
        vm.serializeAddress(k, "factory", address(factory));
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
        vm.serializeBytes32(
            k, "approvalHash", paymaster.approvalHash(op, validUntil, validAfter, maxCost)
        );

        string memory out = _serializeEncodings(k, factory);
        vm.writeJson(out, "./test/fixtures/userop_vector.json");
    }

    /// The three ABI encodings the backend has to produce for itself, pinned
    /// against the compiler's own output.
    function _serializeEncodings(string memory k, SokoniAccountFactory factory)
        internal
        returns (string memory)
    {
        string memory w = vm.readFile(WEBAUTHN_FIXTURE);
        _serializeSignature(k, w);
        _serializeExecute(k);
        return _serializeCreateAccount(
            k, factory, SokoniAccount.Passkey({x: w.readUint(".x"), y: w.readUint(".y")})
        );
    }

    /// 1. The passkey signature, in the shape validateUserOp decodes.
    function _serializeSignature(string memory k, string memory w) internal {
        WebAuthn.Auth memory auth = WebAuthn.Auth({
            authenticatorData: w.readBytes(".authenticatorData"),
            clientDataJSON: w.readString(".clientDataJSON"),
            challengeIndex: w.readUint(".challengeIndex"),
            typeIndex: w.readUint(".typeIndex"),
            r: w.readUint(".r"),
            s: w.readUint(".s")
        });
        vm.serializeUint(k, "sigOwnerIndex", OWNER_INDEX);
        vm.serializeBytes(k, "sigAuthenticatorData", auth.authenticatorData);
        // As bytes, not a string: vm.serializeString detects valid JSON and
        // inlines it as a nested object, which is exactly what clientDataJSON
        // is. Hex keeps it an opaque byte string with no escaping ambiguity.
        vm.serializeBytes(k, "sigClientDataJSONHex", bytes(auth.clientDataJSON));
        vm.serializeUint(k, "sigChallengeIndex", auth.challengeIndex);
        vm.serializeUint(k, "sigTypeIndex", auth.typeIndex);
        vm.serializeUint(k, "sigR", auth.r);
        vm.serializeUint(k, "sigS", auth.s);
        vm.serializeBytes(
            k,
            "encodedSignature",
            abi.encode(SokoniAccount.PasskeySignature({ownerIndex: OWNER_INDEX, auth: auth}))
        );
    }

    /// 2. An execute() call — the shape every ordinary operation takes.
    function _serializeExecute(string memory k) internal {
        address target = address(0x00000000000000000000000000000000000000C0);
        uint256 value = 1 ether;
        bytes memory inner = hex"deadbeef";
        vm.serializeAddress(k, "executeTarget", target);
        vm.serializeUint(k, "executeValue", value);
        vm.serializeBytes(k, "executeData", inner);
        vm.serializeBytes(
            k, "encodedExecute", abi.encodeCall(SokoniAccount.execute, (target, value, inner))
        );
    }

    /// 3. Factory createAccount, which becomes factoryData on a first
    /// operation, plus the address it will deploy to — so Go can check its own
    /// counterfactual computation against the factory's.
    function _serializeCreateAccount(
        string memory k,
        SokoniAccountFactory factory,
        SokoniAccount.Passkey memory owner
    ) internal returns (string memory) {
        SokoniAccount.Passkey[] memory owners = new SokoniAccount.Passkey[](1);
        owners[0] = owner;
        vm.serializeBytes32(k, "rpIdHash", RP_ID_HASH);
        vm.serializeUint(k, "ownerX", owner.x);
        vm.serializeUint(k, "ownerY", owner.y);
        vm.serializeUint(k, "salt", SALT);
        vm.serializeAddress(
            k, "counterfactualAccount", factory.getAddress(RP_ID_HASH, owners, SALT)
        );
        return vm.serializeBytes(
            k,
            "encodedCreateAccount",
            abi.encodeCall(SokoniAccountFactory.createAccount, (RP_ID_HASH, owners, SALT))
        );
    }
}
