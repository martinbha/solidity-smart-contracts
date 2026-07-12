// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StreamToken} from "../../src/payments/StreamToken.sol";
import {StreamManager} from "../../src/payments/StreamManager.sol";

/// @notice Deploys the mock stream token and the stream manager, and mints the
///         deployer a working balance so the utils script can open streams
///         immediately.
contract DeployStreamManager is Script {
    uint256 public constant DEPLOYER_BALANCE = 1_000_000 ether;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        StreamToken token = new StreamToken();
        StreamManager manager = new StreamManager();
        token.mint(vm.addr(deployerKey), DEPLOYER_BALANCE);

        vm.stopBroadcast();

        console.log("STREAM_TOKEN:", address(token));
        console.log("STREAM_MANAGER:", address(manager));
    }
}
