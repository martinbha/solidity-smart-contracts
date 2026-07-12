// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChainCanvas} from "../../src/nft/ChainCanvas.sol";

/// @notice Deploys the fully on-chain generative NFT. No wiring needed: the
///         renderer is an internal library and all art state lives in seeds.
contract DeployChainCanvas is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        ChainCanvas canvas = new ChainCanvas();
        vm.stopBroadcast();

        console.log("CHAIN_CANVAS:", address(canvas));
    }
}
