// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BasePaymaster} from "account-abstraction/core/BasePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {_packValidationData} from "account-abstraction/core/Helpers.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title SokoniPaymaster
/// @notice Sponsors gas for Sokoni accounts, on our backend's say-so.
///
/// A new user has no MON. Without sponsorship they cannot send their first
/// userOp, which means they cannot onboard at all — so gas sponsorship is a
/// product requirement here, not a cost optimisation (ADR 2).
///
/// This is a *verifying* paymaster: the sponsorship decision is made off-chain
/// by our backend, which signs an approval that this contract checks. Policy —
/// per-user daily caps, which calls are eligible, whether the account is
/// rate-limited — lives in Go where it can query Postgres and Redis, not in
/// Solidity where it would cost gas and be far harder to change. The contract's
/// only job is to prove the backend actually approved *this* operation at
/// *these* gas parameters.
///
/// Deliberately different from eth-infinitism's `VerifyingPaymaster` sample in
/// three ways, each explained at its use site:
///   1. The approval commits to an explicit `maxCost` ceiling.
///   2. The signer is rotatable rather than immutable.
///   3. `paymasterAndData` is packed, not `abi.encode`d, saving 52 bytes.
contract SokoniPaymaster is BasePaymaster {
    using MessageHashUtils for bytes32;

    /// @dev Layout of `paymasterAndData`. The first 52 bytes are fixed by
    /// ERC-4337 v0.7 itself (address, then the two paymaster gas limits); we
    /// choose everything from 52 on.
    ///
    /// The sample encodes the timestamps with `abi.encode(uint48, uint48)`,
    /// which spends 64 bytes to carry 12 bytes of information. Packing them
    /// saves 52 bytes of calldata on every sponsored operation. That is worth
    /// doing on Monad specifically: gas is charged on the limit rather than the
    /// amount used, so calldata we never needed is a cost we pay every time.
    ///
    ///     [ 0: 20]  paymaster address
    ///     [20: 36]  paymasterVerificationGasLimit   (fixed by ERC-4337)
    ///     [36: 52]  paymasterPostOpGasLimit         (fixed by ERC-4337)
    ///     [52: 58]  validUntil   uint48
    ///     [58: 64]  validAfter   uint48
    ///     [64: 80]  maxCost      uint128
    ///     [80:145]  signature    65 bytes
    uint256 internal constant VALID_UNTIL_OFFSET = 52;
    uint256 internal constant VALID_AFTER_OFFSET = 58;
    uint256 internal constant MAX_COST_OFFSET = 64;
    uint256 internal constant SIGNATURE_OFFSET = 80;
    uint256 internal constant PAYMASTER_DATA_LENGTH = 145;

    /// @dev Mirrors the account's convention. Validation must never revert.
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    /// @notice The backend key whose approval this paymaster honours.
    ///
    /// Rotatable, unlike the sample's immutable signer. A paymaster holds a
    /// deposit and a stake at the EntryPoint; if the signing key leaks, the
    /// remedy must not be "deploy a new paymaster, move the deposit, wait out
    /// the unstake delay, and update every client". Rotation makes containment
    /// a single transaction.
    ///
    /// Reading this during validation is storage access, which ERC-7562
    /// permits a paymaster only for its *own* storage and only when staked.
    /// `addStake` is therefore not optional for this contract — see the deploy
    /// script and ADR 8.
    address public signer;

    event SignerRotated(address indexed previous, address indexed current);

    error SignerIsZero();

    constructor(IEntryPoint entryPoint_, address signer_) BasePaymaster(entryPoint_) {
        if (signer_ == address(0)) revert SignerIsZero();
        signer = signer_;
        emit SignerRotated(address(0), signer_);
    }

    /// @notice Point the paymaster at a new backend signing key.
    function rotateSigner(address next) external onlyOwner {
        if (next == address(0)) revert SignerIsZero();
        emit SignerRotated(signer, next);
        signer = next;
    }

    // ------------------------------------------------------------- validation

    /// @inheritdoc BasePaymaster
    /// @dev Returns an empty context, so `postOp` is never called and
    /// `paymasterPostOpGasLimit` can be zero. We have nothing to settle after
    /// the fact: the backend already decided, and it records the spend from the
    /// indexed `UserOperationEvent` rather than from an on-chain callback.
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32, /* userOpHash */
        uint256 requiredPreFund
    ) internal view override returns (bytes memory context, uint256 validationData) {
        bytes calldata pmd = userOp.paymasterAndData;

        // A malformed approval is a refusal, not a revert. Reverting here fails
        // the whole bundle and can get the paymaster banned by bundlers, which
        // is the same trap the account avoids in its own validation (ADR 7).
        if (pmd.length != PAYMASTER_DATA_LENGTH) {
            return ("", SIG_VALIDATION_FAILED);
        }

        uint48 validUntil = uint48(bytes6(pmd[VALID_UNTIL_OFFSET:VALID_AFTER_OFFSET]));
        uint48 validAfter = uint48(bytes6(pmd[VALID_AFTER_OFFSET:MAX_COST_OFFSET]));
        uint128 maxCost = uint128(bytes16(pmd[MAX_COST_OFFSET:SIGNATURE_OFFSET]));

        // The ceiling the backend committed to. The signed gas fields already
        // bound the cost arithmetically, but that bound is only as good as the
        // backend's own multiplication. This is the same number computed by the
        // EntryPoint instead of by us, so an estimation bug costs one rejected
        // operation rather than a drained deposit.
        if (requiredPreFund > maxCost) {
            return ("", SIG_VALIDATION_FAILED);
        }

        bytes32 digest =
            approvalHash(userOp, validUntil, validAfter, maxCost).toEthSignedMessageHash();

        // `tryRecover` rather than `recover`: a malformed signature must return
        // a failure code, and `recover` reverts.
        (address recovered, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(digest, pmd[SIGNATURE_OFFSET:]);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) {
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        return ("", _packValidationData(false, validUntil, validAfter));
    }

    /// @notice The digest the backend signs to approve one operation.
    ///
    /// @dev Covers every field that determines what this sponsorship costs us
    /// and who it is for. Note what is *excluded* and why:
    ///
    ///   - `paymasterAndData` as a whole, because it carries this signature.
    ///     The two paymaster gas limits inside it are included explicitly via
    ///     the [20:52] slice, since they are ours to pay for.
    ///   - `userOp.signature`, because the passkey signature is produced after
    ///     the backend hands the userOpHash to the phone. Including it would
    ///     make sponsorship un-signable before the user has signed. The account
    ///     verifies that half; we verify the gas half.
    ///
    /// Binding to `sender` and `nonce` is what stops an approval being replayed:
    /// the EntryPoint will not accept the same nonce twice, so an approval is
    /// spent exactly once.
    function approvalHash(
        PackedUserOperation calldata userOp,
        uint48 validUntil,
        uint48 validAfter,
        uint128 maxCost
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                // The paymaster's own gas limits, as the EntryPoint will read them.
                bytes32(
                    userOp.paymasterAndData[PAYMASTER_VALIDATION_GAS_OFFSET:PAYMASTER_DATA_OFFSET]
                ),
                userOp.preVerificationGas,
                userOp.gasFees,
                block.chainid,
                address(this),
                validUntil,
                validAfter,
                maxCost
            )
        );
    }

    /// @notice Assemble `paymasterAndData` from an approval.
    /// @dev Exposed so tests and the Go backend can be checked against one
    /// definition of the layout rather than two that drift.
    function encodePaymasterAndData(
        uint128 verificationGasLimit,
        uint128 postOpGasLimit,
        uint48 validUntil,
        uint48 validAfter,
        uint128 maxCost,
        bytes memory signature
    ) external view returns (bytes memory) {
        return abi.encodePacked(
            address(this),
            verificationGasLimit,
            postOpGasLimit,
            validUntil,
            validAfter,
            maxCost,
            signature
        );
    }
}
