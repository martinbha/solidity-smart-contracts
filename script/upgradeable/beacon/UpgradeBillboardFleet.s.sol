// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BeaconBillboardV2} from "../../../src/upgradeable/beacon/BeaconBillboardV2.sol";
import {BillboardFactory} from "../../../src/upgradeable/beacon/BillboardFactory.sol";

/// @notice Fleet upgrade: deploys the V2 implementation and flips the shared
///         beacon via the factory — ONE transaction upgrades every instance,
///         however many exist.
contract UpgradeBillboardFleet is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        BillboardFactory factory = BillboardFactory(vm.envAddress("FLEET_FACTORY"));

        vm.startBroadcast(deployerKey);

        BeaconBillboardV2 newImplementation = new BeaconBillboardV2();
        factory.upgradeFleet(address(newImplementation));

        vm.stopBroadcast();

        console.log("FLEET_IMPLEMENTATION_V2:", address(newImplementation));
        console.log("FLEET_FACTORY:", address(factory));
        console.log("FLEET_SIZE_UPGRADED:", factory.billboardCount());
    }
}
