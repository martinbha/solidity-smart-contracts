// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Billboard} from "../../src/upgradeable/Billboard.sol";

/// @notice Initial deploy: implementation + ERC1967 proxy, initialized atomically.
///         The proxy address printed here is the contract's permanent address.
contract DeployBillboard is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerKey);
        string memory initialMessage = vm.envOr("INITIAL_MESSAGE", string("gm, world"));

        vm.startBroadcast(deployerKey);

        Billboard implementation = new Billboard();
        // Deploy the proxy and run initialize() in the same transaction so
        // nobody can front-run the initialization.
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Billboard.initialize, (owner, initialMessage))
        );

        vm.stopBroadcast();

        console.log("BILLBOARD_IMPLEMENTATION:", address(implementation));
        console.log("BILLBOARD_PROXY:", address(proxy));
        console.log("OWNER:", owner);
    }
}
