// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {SokoniAccount} from "./SokoniAccount.sol";

/// @title SokoniAccountFactory
/// @notice Deploys passkey accounts at addresses known before they exist.
///
/// Counterfactual deployment is what lets onboarding feel instant: we can show
/// the user their address, and let them receive funds at it, before any
/// transaction has been sent. The account is deployed by the first userOp,
/// through ERC-4337 initCode.
contract SokoniAccountFactory {
    /// @notice Shared implementation behind every account proxy.
    SokoniAccount public immutable implementation;

    event AccountCreated(address indexed account, bytes32 indexed salt);

    error NoOwners();

    constructor(IEntryPoint entryPoint) {
        implementation = new SokoniAccount(entryPoint);
    }

    /// @notice Create the account, or return it if it already exists.
    /// @dev Idempotent on purpose. A bundler may submit the same initCode more
    /// than once, and reverting on the second attempt would strand the userOp.
    function createAccount(bytes32 rpIdHash, SokoniAccount.Passkey[] calldata owners, uint256 salt)
        external
        returns (SokoniAccount account)
    {
        if (owners.length == 0) revert NoOwners();

        bytes32 fullSalt = _salt(rpIdHash, owners, salt);
        (bool alreadyDeployed, address addr) =
            LibClone.createDeterministicERC1967(address(implementation), fullSalt);

        account = SokoniAccount(payable(addr));
        if (!alreadyDeployed) {
            account.initialize(rpIdHash, owners);
            emit AccountCreated(addr, fullSalt);
        }
    }

    /// @notice The address `createAccount` would produce for these arguments.
    function getAddress(bytes32 rpIdHash, SokoniAccount.Passkey[] calldata owners, uint256 salt)
        external
        view
        returns (address)
    {
        return LibClone.predictDeterministicAddressERC1967(
            address(implementation), _salt(rpIdHash, owners, salt), address(this)
        );
    }

    /// @dev The salt commits to the owner set, so the same passkey deterministically
    /// recovers the same address on a new device, and a different key cannot
    /// land on someone else's account.
    function _salt(bytes32 rpIdHash, SokoniAccount.Passkey[] calldata owners, uint256 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(rpIdHash, owners, salt));
    }
}
