// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RockPaperScissors} from "../../src/games/RockPaperScissors.sol";

/// @notice Deploys the RockPaperScissors game contract. Stateless deploy —
///         games are created by players afterwards (see utils/games/deploy_rps.sh
///         for a full scripted match).
contract DeployRPS is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        RockPaperScissors rps = new RockPaperScissors();
        vm.stopBroadcast();

        console.log("RPS_ADDRESS:", address(rps));
        console.log("REVEAL_WINDOW:", rps.REVEAL_WINDOW());
    }
}
