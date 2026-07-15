// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {SmartAccountFactory} from "../../src/accounts/SmartAccountFactory.sol";
import {SponsorPaymaster} from "../../src/accounts/SponsorPaymaster.sol";

/// @notice A minimal target the demo op calls, so the run has an on-chain
///         effect to verify. `ping()` is the "app" the paymaster sponsors.
contract PingTarget {
    uint256 public pings;

    function ping() external {
        pings++;
    }
}

/// @notice Deploys the ERC-4337 stack for a local run: a fresh EntryPoint
///         (mainnet has a canonical singleton; anvil needs its own), the
///         account factory, the sponsor paymaster, and a demo target. Funds
///         the paymaster's EntryPoint deposit and allowlists the target so it
///         will sponsor ops that call it.
contract DeploySmartAccount is Script {
    uint256 public constant PAYMASTER_DEPOSIT = 5 ether;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        EntryPoint entryPoint = new EntryPoint();
        SmartAccountFactory factory = new SmartAccountFactory(IEntryPoint(address(entryPoint)));
        SponsorPaymaster paymaster = new SponsorPaymaster(IEntryPoint(address(entryPoint)));
        PingTarget target = new PingTarget();

        paymaster.deposit{value: PAYMASTER_DEPOSIT}();
        paymaster.setAllowed(address(target), true);

        vm.stopBroadcast();

        console.log("ENTRY_POINT:", address(entryPoint));
        console.log("FACTORY:", address(factory));
        console.log("PAYMASTER:", address(paymaster));
        console.log("TARGET:", address(target));
    }
}
