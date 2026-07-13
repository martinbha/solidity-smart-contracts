// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PermitToken} from "../../src/signatures/PermitToken.sol";
import {MinimalForwarder} from "../../src/signatures/MinimalForwarder.sol";
import {GaslessVault} from "../../src/signatures/GaslessVault.sol";

/// @notice Deploys the gasless stack: the EIP-2612 permit token, the ERC-2771
///         forwarder, and the vault that trusts it. The vault's trusted
///         forwarder is fixed at construction — the one security-critical
///         wiring decision in the whole setup.
contract DeployGasless is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        PermitToken token = new PermitToken();
        MinimalForwarder forwarder = new MinimalForwarder();
        GaslessVault vault = new GaslessVault(IERC20(address(token)), address(forwarder));

        vm.stopBroadcast();

        console.log("PERMIT_TOKEN:", address(token));
        console.log("FORWARDER:", address(forwarder));
        console.log("GASLESS_VAULT:", address(vault));
    }
}
