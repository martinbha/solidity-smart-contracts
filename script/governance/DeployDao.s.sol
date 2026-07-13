// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovToken} from "../../src/governance/GovToken.sol";
import {DaoGovernor} from "../../src/governance/DaoGovernor.sol";
import {Treasury} from "../../src/governance/Treasury.sol";

/// @notice Deploys the full DAO stack and wires the roles: token → timelock →
///         governor → treasury. The Governor is the timelock's only proposer
///         and canceller, anyone may execute a ready operation, and the
///         deployer renounces the timelock admin role — after this script no
///         single key can move the treasury; only proposals can.
contract DeployDao is Script {
    uint256 public constant MIN_DELAY = 60; // demo-sized; production uses days
    uint256 public constant VOTER_SUPPLY = 1000 ether;
    uint256 public constant TREASURY_FUNDS = 25 ether;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        GovToken token = new GovToken();
        TimelockController timelock = new TimelockController(MIN_DELAY, new address[](0), new address[](0), deployer);
        DaoGovernor governor = new DaoGovernor(token, timelock);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        Treasury treasury = new Treasury(address(timelock));
        (bool funded,) = address(treasury).call{value: TREASURY_FUNDS}("");
        require(funded, "treasury funding failed");

        token.mint(deployer, VOTER_SUPPLY);

        vm.stopBroadcast();

        console.log("GOV_TOKEN:", address(token));
        console.log("TIMELOCK:", address(timelock));
        console.log("DAO_GOVERNOR:", address(governor));
        console.log("TREASURY:", address(treasury));
    }
}
