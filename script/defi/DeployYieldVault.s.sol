// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultAsset} from "../../src/defi/VaultAsset.sol";
import {MockYieldSource} from "../../src/defi/MockYieldSource.sol";
import {YieldVault} from "../../src/defi/YieldVault.sol";

/// @notice Deploys the underlying asset, the mock yield source, and the vault;
///         wires them together, funds the source's yield reserve, and sets a
///         10% per-harvest rate so the utils script has yield to demonstrate.
contract DeployYieldVault is Script {
    uint256 public constant YIELD_RESERVE = 1_000_000 ether;
    uint256 public constant YIELD_RATE_BPS = 1_000; // 10% per harvest

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        VaultAsset asset = new VaultAsset();
        MockYieldSource source = new MockYieldSource(IERC20(address(asset)));
        YieldVault vault = new YieldVault(IERC20(address(asset)), source);
        source.setVault(address(vault));

        asset.mint(vm.addr(deployerKey), YIELD_RESERVE);
        asset.approve(address(source), YIELD_RESERVE);
        source.fund(YIELD_RESERVE);

        vault.setYieldRate(YIELD_RATE_BPS);

        vm.stopBroadcast();

        console.log("VAULT_ASSET:", address(asset));
        console.log("YIELD_SOURCE:", address(source));
        console.log("YIELD_VAULT:", address(vault));
    }
}
