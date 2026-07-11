// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MultisigWallet} from "../../src/wallets/MultisigWallet.sol";

/// @notice Deploys a 2-of-3 MultisigWallet owned by the first three Anvil
///         accounts, so the utils script can demonstrate an off-chain-signed
///         m-of-n transfer against a local node.
contract DeployMultisig is Script {
    uint256 public constant THRESHOLD = 2;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address[] memory owners = new address[](3);
        owners[0] = vm.envAddress("OWNER_0");
        owners[1] = vm.envAddress("OWNER_1");
        owners[2] = vm.envAddress("OWNER_2");

        vm.startBroadcast(deployerKey);
        MultisigWallet wallet = new MultisigWallet(owners, THRESHOLD);
        vm.stopBroadcast();

        console.log("MULTISIG_WALLET:", address(wallet));
    }
}
