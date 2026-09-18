// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {SimpleAccountFactory} from "account-abstraction/samples/SimpleAccountFactory.sol";

/// Deploys the ECDSA-owned account path (Option 2: a Mera-derived key owns a
/// plain `SimpleAccount` instead of a WebAuthn/P-256 `SokoniAccount`).
///
/// Deliberately the *unmodified*, audited reference implementation from
/// eth-infinitism's account-abstraction repo (already vendored at
/// lib/account-abstraction/contracts/samples/), not a rewrite: `SimpleAccount`
/// only exposes execute/executeBatch/ERC-1271 through the same IAccount
/// surface SokoniAccount does, and SokoniPaymaster never calls into the
/// account at all (it only reads userOp.sender/nonce/initCode/callData — see
/// SokoniPaymaster.sol), so the existing paymaster sponsors this account with
/// zero changes on either side.
///
/// SokoniAccount/SokoniAccountFactory are untouched by this — this adds a
/// second, additive account path rather than replacing the first.
///
///     forge script script/DeployMeraAccountFactory.s.sol \
///       --rpc-url "$MONAD_RPC_HTTP" --broadcast
///
/// Reads PRIVATE_KEY and ENTRYPOINT.
contract DeployMeraAccountFactory is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address entryPoint = vm.envAddress("ENTRYPOINT");

        vm.startBroadcast(deployerKey);
        SimpleAccountFactory factory = new SimpleAccountFactory(IEntryPoint(entryPoint));
        vm.stopBroadcast();

        console.log("MeraAccountFactory (SimpleAccountFactory):", address(factory));
        console.log("accountImplementation                    :", address(factory.accountImplementation()));
        console.log("entryPoint                                :", entryPoint);
        console.log("");
        console.log("Set SOKONI_MERA_FACTORY to the address above.");
        console.log("SokoniPaymaster and SOKONI_PAYMASTER are reused as-is -- this factory");
        console.log("needs no paymaster changes.");
    }
}
