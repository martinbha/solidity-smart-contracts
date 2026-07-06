// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BillboardV2} from "../../src/upgradeable/BillboardV2.sol";

/// @notice Upgrade: deploys the V2 implementation and points the existing
///         proxy at it. State in the proxy is untouched.
contract UpgradeBillboard is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("BILLBOARD_PROXY");

        vm.startBroadcast(deployerKey);

        BillboardV2 newImplementation = new BillboardV2();
        // No migration call needed for this upgrade, so calldata is empty.
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImplementation), "");

        vm.stopBroadcast();

        console.log("BILLBOARD_IMPLEMENTATION_V2:", address(newImplementation));
        console.log("BILLBOARD_PROXY:", proxy);
    }
}
