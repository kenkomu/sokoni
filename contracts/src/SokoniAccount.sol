// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {WebAuthn} from "./lib/WebAuthn.sol";

/// @title SokoniAccount
/// @notice An ERC-4337 account controlled by passkeys.
///
/// The user's key lives in the phone's Secure Enclave or Android Keystore and
/// never leaves it. There is no seed phrase and no exportable secret; the
/// account is authorised by a WebAuthn assertion verified on-chain through
/// Monad's secp256r1 precompile.
///
/// Several credentials can own one account, which is what makes multi-device
/// and recovery possible: a second phone registers its own passkey, authorised
/// by an existing one.
contract SokoniAccount is IAccount {
    struct Passkey {
        uint256 x;
        uint256 y;
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @dev Signature payload. `ownerIndex` says which credential signed, so
    /// validation does not have to try every registered key in turn.
    struct PasskeySignature {
        uint256 ownerIndex;
        WebAuthn.Auth auth;
    }

    /// @dev ERC-4337 v0.7 sentinel for a failed signature check. Validation
    /// must RETURN this rather than revert — reverting during validation gets
    /// the whole bundle rejected and can get the bundler to ban the sender.
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;

    /// @dev ERC-1271 magic value.
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;

    /// @notice The EntryPoint this account trusts. Immutable by design: a
    /// mutable EntryPoint is a total-control upgrade path.
    IEntryPoint public immutable entryPoint;

    /// @notice sha256(rpId) the credentials must be bound to. Zero disables the
    /// check, which is only appropriate in tests.
    bytes32 public rpIdHash;

    Passkey[] internal _owners;
    /// @dev keccak256(x, y) => registered. Guards against duplicate owners.
    mapping(bytes32 => bool) public isOwner;

    bool internal _initialized;

    event OwnerAdded(uint256 indexed index, uint256 x, uint256 y);
    event OwnerRemoved(uint256 indexed index, uint256 x, uint256 y);

    error AlreadyInitialized();
    error NotEntryPoint();
    error NotSelfOrEntryPoint();
    error NoOwners();
    error DuplicateOwner();
    error OwnerIndexOutOfRange();
    error CannotRemoveLastOwner();
    error CallFailed(uint256 index, bytes reason);

    constructor(IEntryPoint entryPoint_) {
        entryPoint = entryPoint_;
        // Stop the implementation itself being initialised and driven directly.
        _initialized = true;
    }

    /// @notice Initialise a freshly cloned account.
    function initialize(bytes32 rpIdHash_, Passkey[] calldata owners_) external {
        if (_initialized) revert AlreadyInitialized();
        if (owners_.length == 0) revert NoOwners();
        _initialized = true;
        rpIdHash = rpIdHash_;
        for (uint256 i; i < owners_.length; ++i) {
            _addOwner(owners_[i]);
        }
    }

    // -------------------------------------------------------------- validation

    /// @inheritdoc IAccount
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override returns (uint256 validationData) {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();

        validationData = _validateSignature(userOpHash, userOp.signature);

        // Pay the EntryPoint what it is owed regardless of the signature
        // outcome, per ERC-4337: the bundler spent gas either way.
        if (missingAccountFunds != 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
            ok; // deliberately unchecked — EntryPoint reconciles the deposit
        }
    }

    /// @notice ERC-1271, so the account can authorise off-chain messages too.
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        return _validateSignature(hash, signature) == SIG_VALIDATION_SUCCESS
            ? ERC1271_MAGIC
            : bytes4(0xffffffff);
    }

    function _validateSignature(bytes32 hash, bytes calldata signature)
        internal
        view
        returns (uint256)
    {
        // A malformed signature is an invalid signature, not a revert. During
        // the 4337 validation phase a revert costs the whole bundle.
        if (signature.length == 0) return SIG_VALIDATION_FAILED;

        PasskeySignature memory sig;
        // solhint-disable-next-line no-inline-assembly
        try this.decodeSignature(signature) returns (PasskeySignature memory decoded) {
            sig = decoded;
        } catch {
            return SIG_VALIDATION_FAILED;
        }

        if (sig.ownerIndex >= _owners.length) return SIG_VALIDATION_FAILED;
        Passkey memory owner = _owners[sig.ownerIndex];

        // A removed owner is zeroed rather than shifted, so indices stay stable.
        if (owner.x == 0 && owner.y == 0) return SIG_VALIDATION_FAILED;

        bool ok = WebAuthn.verify({
            challenge: abi.encode(hash),
            // User verification is required, not merely user presence: this
            // account moves money, so a tap is not enough — we want the
            // biometric or PIN that proves who tapped.
            requireUV: true,
            expectedRpIdHash: rpIdHash,
            auth: sig.auth,
            x: owner.x,
            y: owner.y
        });

        return ok ? SIG_VALIDATION_SUCCESS : SIG_VALIDATION_FAILED;
    }

    /// @dev External only so `_validateSignature` can try/catch a malformed
    /// payload. Never call this from anywhere else.
    function decodeSignature(bytes calldata signature)
        external
        pure
        returns (PasskeySignature memory)
    {
        return abi.decode(signature, (PasskeySignature));
    }

    // ---------------------------------------------------------------- execution

    function execute(address target, uint256 value, bytes calldata data)
        external
        onlySelfOrEntryPoint
    {
        _call(0, target, value, data);
    }

    function executeBatch(Call[] calldata calls) external onlySelfOrEntryPoint {
        for (uint256 i; i < calls.length; ++i) {
            _call(i, calls[i].target, calls[i].value, calls[i].data);
        }
    }

    function _call(uint256 index, address target, uint256 value, bytes calldata data) internal {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed(index, ret);
    }

    // ------------------------------------------------------------------- owners

    /// @notice Register another credential. Reachable only through a userOp
    /// signed by an existing owner, so adding a device requires the old one.
    function addOwner(Passkey calldata key) external onlySelfOrEntryPoint {
        _addOwner(key);
    }

    function removeOwner(uint256 index) external onlySelfOrEntryPoint {
        if (index >= _owners.length) revert OwnerIndexOutOfRange();
        Passkey memory key = _owners[index];
        if (key.x == 0 && key.y == 0) revert OwnerIndexOutOfRange();
        if (ownerCount() == 1) revert CannotRemoveLastOwner();

        delete isOwner[keccak256(abi.encode(key.x, key.y))];
        _owners[index] = Passkey(0, 0);
        emit OwnerRemoved(index, key.x, key.y);
    }

    function _addOwner(Passkey memory key) internal {
        bytes32 id = keccak256(abi.encode(key.x, key.y));
        if (isOwner[id]) revert DuplicateOwner();
        isOwner[id] = true;
        _owners.push(key);
        emit OwnerAdded(_owners.length - 1, key.x, key.y);
    }

    function ownerAt(uint256 index) external view returns (Passkey memory) {
        if (index >= _owners.length) revert OwnerIndexOutOfRange();
        return _owners[index];
    }

    function ownerSlots() external view returns (uint256) {
        return _owners.length;
    }

    /// @notice Live owners, excluding removed slots.
    function ownerCount() public view returns (uint256 n) {
        for (uint256 i; i < _owners.length; ++i) {
            if (_owners[i].x != 0 || _owners[i].y != 0) ++n;
        }
    }

    // ------------------------------------------------------------------ plumbing

    modifier onlySelfOrEntryPoint() {
        if (msg.sender != address(this) && msg.sender != address(entryPoint)) {
            revert NotSelfOrEntryPoint();
        }
        _;
    }

    receive() external payable {}
}
