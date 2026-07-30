// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BatchDelegate} from "../../../src/accounts/eip7702/BatchDelegate.sol";

/// @notice Deploys the reusable implementation that EIP-7702 accounts can
///         designate as their code.
contract DeployBatchDelegate is Script {
    function run() external returns (BatchDelegate implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        implementation = new BatchDelegate();
        vm.stopBroadcast();

        console.log("BATCH_DELEGATE:", address(implementation));
    }
}
