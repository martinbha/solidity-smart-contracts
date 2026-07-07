// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BeaconBillboard} from "../../../src/upgradeable/beacon/BeaconBillboard.sol";
import {BillboardFactory} from "../../../src/upgradeable/beacon/BillboardFactory.sol";

/// @notice Initial fleet deploy: V1 implementation + factory (which spawns the
///         shared beacon), then three sample billboard instances so the
///         upgrade script has a real fleet to flip.
contract DeployBillboardFleet is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address fleetAdmin = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        BeaconBillboard implementation = new BeaconBillboard();
        BillboardFactory factory = new BillboardFactory(address(implementation), fleetAdmin);

        // A small starter fleet, all owned by the deployer. Salts must differ
        // per (creator, salt) pair since instances are CREATE2-deployed.
        address boardA = factory.createBillboard("fleet board alpha", bytes32(uint256(0)));
        address boardB = factory.createBillboard("fleet board bravo", bytes32(uint256(1)));
        address boardC = factory.createBillboard("fleet board charlie", bytes32(uint256(2)));

        vm.stopBroadcast();

        console.log("FLEET_IMPLEMENTATION:", address(implementation));
        console.log("FLEET_FACTORY:", address(factory));
        console.log("FLEET_BEACON:", address(factory.beacon()));
        console.log("FLEET_INSTANCE_0:", boardA);
        console.log("FLEET_INSTANCE_1:", boardB);
        console.log("FLEET_INSTANCE_2:", boardC);
        console.log("FLEET_ADMIN:", fleetAdmin);
    }
}
