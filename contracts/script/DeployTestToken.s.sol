// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TestToken} from "account-abstraction/test/TestToken.sol";

/// Deploys eth-infinitism's own TestToken (vendored, unmodified) with a
/// public, unrestricted mint() — purely so the Option 2 / Mera end-to-end
/// proof has a sponsored token it can actually fund without depending on an
/// existing test token whose holder/mint access is unknown.
///
///     forge script script/DeployTestToken.s.sol --rpc-url "$MONAD_RPC_HTTP" --broadcast
///
/// Reads PRIVATE_KEY.
contract DeployTestToken is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        TestToken token = new TestToken();
        vm.stopBroadcast();

        console.log("TestToken:", address(token));
        console.log("");
        console.log("Append to SPONSORED_TOKENS as <address>:TST2:18");
    }
}
