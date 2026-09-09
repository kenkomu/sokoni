// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {SokoniAccount} from "../src/SokoniAccount.sol";
import {SokoniAccountFactory} from "../src/SokoniAccountFactory.sol";
import {WebAuthn} from "../src/lib/WebAuthn.sol";

/// End-to-end proof of the Phase 1 thesis: a device-held P-256 key, with no
/// seed phrase and no MON of its own, drives an ERC-4337 account on Monad.
///
/// Signatures here are produced at runtime by script/gen_webauthn_vector.py
/// over the actual userOpHash, not replayed from a fixture — otherwise the test
/// would only prove the account accepts one signature it was built around.
///
/// Runs under `network = "monad"` so the secp256r1 precompile at 0x0100 exists.
contract SokoniAccountTest is Test {
    using stdJson for string;

    /// sha256("sokoni.app")
    bytes32 constant RP_ID_HASH =
        0x6b4acac5333939cbe4e8b6d4861c3f455146a279a0cec6fa65b45ed8bc305492;

    EntryPoint entryPoint;
    SokoniAccountFactory factory;
    SokoniAccount account;

    address payable beneficiary = payable(address(0xB0B));
    address recipient = address(0xCAFE);

    function setUp() public {
        entryPoint = new EntryPoint();
        factory = new SokoniAccountFactory(IEntryPoint(address(entryPoint)));

        SokoniAccount.Passkey[] memory owners = new SokoniAccount.Passkey[](1);
        owners[0] = _pubkey(false);

        account = factory.createAccount(RP_ID_HASH, owners, 0);
        vm.deal(address(account), 10 ether);
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

    /// Sign `challenge` with the test passkey and pack it the way the account expects.
    function _sign(bytes32 challenge, uint256 ownerIndex, string memory variant)
        internal
        returns (bytes memory)
    {
        uint256 n = bytes(variant).length == 0 ? 3 : 4;
        string[] memory cmd = new string[](n);
        cmd[0] = "python3";
        cmd[1] = "script/gen_webauthn_vector.py";
        cmd[2] = "--sign";
        // vm.toString on bytes32 gives the 0x-prefixed hex the script expects.
        string[] memory full = new string[](n + 1);
        for (uint256 i; i < 3; ++i) {
            full[i] = cmd[i];
        }
        full[3] = vm.toString(challenge);
        if (n == 4) full[4] = variant;

        string memory out = string(vm.ffi(full));

        WebAuthn.Auth memory auth = WebAuthn.Auth({
            authenticatorData: out.readBytes(".authenticatorData"),
            clientDataJSON: out.readString(".clientDataJSON"),
            challengeIndex: out.readUint(".challengeIndex"),
            typeIndex: out.readUint(".typeIndex"),
            r: out.readUint(".r"),
            s: out.readUint(".s")
        });
        return abi.encode(SokoniAccount.PasskeySignature({ownerIndex: ownerIndex, auth: auth}));
    }

    function _userOp(bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op.sender = address(account);
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = callData;
        // verificationGasLimit << 128 | callGasLimit
        op.accountGasLimits = bytes32(uint256(600_000) << 128 | uint256(400_000));
        op.preVerificationGas = 100_000;
        // maxPriorityFeePerGas << 128 | maxFeePerGas
        op.gasFees = bytes32(uint256(1 gwei) << 128 | uint256(100 gwei));
    }

    function _handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }

    // -------------------------------------------------------------------- tests

    /// The headline: a passkey moves money through ERC-4337, no seed phrase.
    function test_PasskeyDrivesUserOpEndToEnd() public {
        PackedUserOperation memory op =
            _userOp(abi.encodeCall(SokoniAccount.execute, (recipient, 1 ether, "")));
        op.signature = _sign(entryPoint.getUserOpHash(op), 0, "");

        assertEq(recipient.balance, 0);
        _handle(op);
        assertEq(recipient.balance, 1 ether, "passkey-signed transfer must land");
    }

    function test_RejectsSignatureOverADifferentUserOp() public {
        PackedUserOperation memory op =
            _userOp(abi.encodeCall(SokoniAccount.execute, (recipient, 1 ether, "")));
        // Sign a different hash: a replayed or mismatched assertion must fail.
        op.signature = _sign(keccak256("some other operation"), 0, "");

        vm.expectRevert();
        _handle(op);
    }

    function test_RejectsSignatureFromUnregisteredPasskey() public {
        PackedUserOperation memory op =
            _userOp(abi.encodeCall(SokoniAccount.execute, (recipient, 1 ether, "")));
        // Signed by the second key, which was never added as an owner.
        op.signature = _sign(entryPoint.getUserOpHash(op), 0, "second");

        vm.expectRevert();
        _handle(op);
    }

    /// This account moves money, so presence alone is not enough.
    function test_RejectsAssertionWithoutUserVerification() public {
        PackedUserOperation memory op =
            _userOp(abi.encodeCall(SokoniAccount.execute, (recipient, 1 ether, "")));
        op.signature = _sign(entryPoint.getUserOpHash(op), 0, "no-uv");

        vm.expectRevert();
        _handle(op);
    }

    function test_RejectsRegistrationAssertionAsAuthorisation() public {
        PackedUserOperation memory op =
            _userOp(abi.encodeCall(SokoniAccount.execute, (recipient, 1 ether, "")));
        op.signature = _sign(entryPoint.getUserOpHash(op), 0, "create");

        vm.expectRevert();
        _handle(op);
    }

    /// Adding a device is authorised by an existing passkey, then the new one works.
    function test_SecondDeviceCanBeAddedAndThenSigns() public {
        SokoniAccount.Passkey memory second = _pubkey(true);

        PackedUserOperation memory add = _userOp(abi.encodeCall(SokoniAccount.addOwner, (second)));
        add.signature = _sign(entryPoint.getUserOpHash(add), 0, "");
        _handle(add);

        assertEq(account.ownerCount(), 2, "second device registered");

        PackedUserOperation memory spend =
            _userOp(abi.encodeCall(SokoniAccount.execute, (recipient, 2 ether, "")));
        spend.signature = _sign(entryPoint.getUserOpHash(spend), 1, "second");
        _handle(spend);

        assertEq(recipient.balance, 2 ether, "new device must be able to spend");
    }

    function test_CannotRemoveTheLastOwner() public {
        // Direct call: the guard itself.
        vm.prank(address(account));
        vm.expectRevert(SokoniAccount.CannotRemoveLastOwner.selector);
        account.removeOwner(0);
    }

    /// Through the EntryPoint the guard shows up as an unchanged owner set, not
    /// a bubbled revert: handleOps catches reverts from the execution phase and
    /// emits UserOperationRevertReason instead of failing the bundle. Only
    /// *validation* failures propagate, which is why the signature tests above
    /// can expectRevert and this one cannot.
    function test_RemovingLastOwnerViaUserOpLeavesOwnersIntact() public {
        PackedUserOperation memory op = _userOp(abi.encodeCall(SokoniAccount.removeOwner, (0)));
        op.signature = _sign(entryPoint.getUserOpHash(op), 0, "");

        vm.recordLogs();
        _handle(op);

        assertEq(account.ownerCount(), 1, "the last owner must survive");
    }

    function test_Erc1271AcceptsAPasskeySignature() public {
        bytes32 digest = keccak256("hello sokoni");
        bytes memory sig = _sign(digest, 0, "");
        assertEq(account.isValidSignature(digest, sig), bytes4(0x1626ba7e));
    }

    function test_Erc1271RejectsAnotherKey() public {
        bytes32 digest = keccak256("hello sokoni");
        bytes memory sig = _sign(digest, 0, "second");
        assertEq(account.isValidSignature(digest, sig), bytes4(0xffffffff));
    }

    /// A malformed signature must read as invalid, never revert: a revert during
    /// the 4337 validation phase takes down the whole bundle.
    function test_MalformedSignatureIsInvalidNotARevert() public view {
        assertEq(account.isValidSignature(keccak256("x"), hex"deadbeef"), bytes4(0xffffffff));
        assertEq(account.isValidSignature(keccak256("x"), ""), bytes4(0xffffffff));
    }

    function test_OnlyEntryPointCanValidate() public {
        PackedUserOperation memory op = _userOp("");
        vm.expectRevert(SokoniAccount.NotEntryPoint.selector);
        account.validateUserOp(op, bytes32(0), 0);
    }

    function test_OnlyEntryPointOrSelfCanExecute() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(SokoniAccount.NotSelfOrEntryPoint.selector);
        account.execute(recipient, 1 ether, "");
    }

    // ------------------------------------------------------------------ factory

    function test_AddressIsPredictableBeforeDeployment() public {
        SokoniAccount.Passkey[] memory owners = new SokoniAccount.Passkey[](1);
        owners[0] = _pubkey(false);

        address predicted = factory.getAddress(RP_ID_HASH, owners, 42);
        assertEq(predicted.code.length, 0, "must not exist yet");

        SokoniAccount created = factory.createAccount(RP_ID_HASH, owners, 42);
        assertEq(address(created), predicted, "counterfactual address must hold");
    }

    function test_CreateAccountIsIdempotent() public {
        SokoniAccount.Passkey[] memory owners = new SokoniAccount.Passkey[](1);
        owners[0] = _pubkey(false);

        SokoniAccount a = factory.createAccount(RP_ID_HASH, owners, 7);
        SokoniAccount b = factory.createAccount(RP_ID_HASH, owners, 7);
        assertEq(address(a), address(b), "repeat initCode must not revert or fork state");
    }

    function test_ImplementationCannotBeInitialized() public {
        SokoniAccount.Passkey[] memory owners = new SokoniAccount.Passkey[](1);
        owners[0] = _pubkey(false);
        // Hoist the getter: expectRevert binds to the very next call, which
        // would otherwise be the view, not initialize().
        SokoniAccount impl = factory.implementation();
        vm.expectRevert(SokoniAccount.AlreadyInitialized.selector);
        impl.initialize(RP_ID_HASH, owners);
    }

    function test_InitializedAccountCannotBeReinitialized() public {
        SokoniAccount.Passkey[] memory owners = new SokoniAccount.Passkey[](1);
        owners[0] = _pubkey(true);
        vm.expectRevert(SokoniAccount.AlreadyInitialized.selector);
        account.initialize(RP_ID_HASH, owners);
    }
}
