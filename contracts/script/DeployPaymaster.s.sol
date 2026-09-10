// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import {SokoniPaymaster} from "../src/SokoniPaymaster.sol";

/// Deploys SokoniPaymaster, funds its deposit and stakes it.
///
/// All three steps matter and doing only the first produces a paymaster that
/// looks deployed and sponsors nothing:
///
///   - **Deposit** is what actually pays for gas. Without it the EntryPoint
///     rejects every sponsored operation for lack of funds.
///   - **Stake** is what bundlers require before they will accept a paymaster
///     that reads its own storage during validation (ERC-7562). Ours reads the
///     rotatable signer, so this is mandatory, not optional. An unstaked
///     paymaster is rejected with `-32505`, which does not mention staking.
///
/// The unstake delay is a withdrawal timelock on our own funds, not a
/// protection for users. Bundlers set a floor on it; a day is comfortably above
/// what they ask and short enough to be operationally tolerable.
///
///     forge script script/DeployPaymaster.s.sol \
///       --rpc-url "$MONAD_RPC_HTTP" --broadcast
///
/// Reads PRIVATE_KEY, ENTRYPOINT, PAYMASTER_SIGNER, and optionally
/// PAYMASTER_DEPOSIT_WEI, PAYMASTER_STAKE_WEI, PAYMASTER_UNSTAKE_DELAY.
contract DeployPaymaster is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address entryPoint = vm.envAddress("ENTRYPOINT");
        address signer = vm.envAddress("PAYMASTER_SIGNER");

        uint256 deposit = vm.envOr("PAYMASTER_DEPOSIT_WEI", uint256(1 ether));
        uint256 stake = vm.envOr("PAYMASTER_STAKE_WEI", uint256(1 ether));
        uint32 unstakeDelay = uint32(vm.envOr("PAYMASTER_UNSTAKE_DELAY", uint256(1 days)));

        vm.startBroadcast(deployerKey);

        SokoniPaymaster paymaster = new SokoniPaymaster(IEntryPoint(entryPoint), signer);
        paymaster.deposit{value: deposit}();
        paymaster.addStake{value: stake}(unstakeDelay);

        vm.stopBroadcast();

        console.log("SokoniPaymaster :", address(paymaster));
        console.log("entryPoint      :", entryPoint);
        console.log("signer          :", signer);
        console.log("deposit (wei)   :", paymaster.getDeposit());
        console.log("stake (wei)     :", stake);
        console.log("");
        console.log("Set SOKONI_PAYMASTER to the address above.");
        console.log("PAYMASTER_SIGNER must match the key the backend signs with;");
        console.log("the backend checks this at boot and refuses to start on a mismatch.");
    }
}
