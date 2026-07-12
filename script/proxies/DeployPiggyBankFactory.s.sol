// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PiggyBankFactory} from "../../src/proxies/PiggyBankFactory.sol";

/// @notice Deploys the piggy bank clone factory. The factory deploys the
///         canonical implementation itself in its constructor, so one
///         transaction sets up everything the clones will ever need.
contract DeployPiggyBankFactory is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        PiggyBankFactory factory = new PiggyBankFactory();
        vm.stopBroadcast();

        console.log("PIGGY_IMPLEMENTATION:", factory.implementation());
        console.log("PIGGY_FACTORY:", address(factory));
    }
}
