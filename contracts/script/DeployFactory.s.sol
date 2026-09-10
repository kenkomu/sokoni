// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import {SokoniAccountFactory} from "../src/SokoniAccountFactory.sol";

/// Deploys SokoniAccountFactory, which in turn deploys the account
/// implementation every account proxies to.
///
/// Deploy this once per network, before the paymaster is of any use: the
/// factory address goes into `initCode`, so it is baked into the address every
/// account is counterfactually derived at. Redeploying the factory changes
/// every future account address — existing accounts are unaffected, but a user
/// who was shown an address before their first operation would find their funds
/// at the old one. Treat the address as permanent per network.
///
///     forge script script/DeployFactory.s.sol \
///       --rpc-url "$MONAD_RPC_HTTP" --broadcast
///
/// Reads PRIVATE_KEY and ENTRYPOINT.
contract DeployFactory is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address entryPoint = vm.envAddress("ENTRYPOINT");

        vm.startBroadcast(deployerKey);
        SokoniAccountFactory factory = new SokoniAccountFactory(IEntryPoint(entryPoint));
        vm.stopBroadcast();

        console.log("SokoniAccountFactory :", address(factory));
        console.log("  implementation     :", address(factory.implementation()));
        console.log("  entryPoint         :", entryPoint);
        console.log("");
        console.log("Set SOKONI_FACTORY to the factory address above.");
    }
}
