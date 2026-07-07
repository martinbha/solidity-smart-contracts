// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MerkleDistributor} from "../../src/merkle/MerkleDistributor.sol";

/// @notice Submits one claim from deployments/merkle/tree.json, selected by
///         CLAIM_INDEX. The broadcasting key acts as a relayer: it pays gas,
///         but the tokens go to the account proven in the tree.
contract ClaimAirdrop is Script {
    function run() external {
        uint256 relayerKey = vm.envUint("PRIVATE_KEY");
        MerkleDistributor distributor = MerkleDistributor(vm.envAddress("MERKLE_DISTRIBUTOR"));
        uint256 claimIndex = vm.envUint("CLAIM_INDEX");

        string memory treeJson = vm.readFile("deployments/merkle/tree.json");
        string memory base = string.concat(".claims[", vm.toString(claimIndex), "]");
        uint256 index = vm.parseJsonUint(treeJson, string.concat(base, ".index"));
        address account = vm.parseJsonAddress(treeJson, string.concat(base, ".account"));
        uint256 amount = vm.parseJsonUint(treeJson, string.concat(base, ".amount"));
        bytes32[] memory proof =
            vm.parseJsonBytes32Array(treeJson, string.concat(base, ".proof"));

        vm.startBroadcast(relayerKey);
        distributor.claim(index, account, amount, proof);
        vm.stopBroadcast();

        console.log("CLAIMED_INDEX:", index);
        console.log("CLAIMED_ACCOUNT:", account);
        console.log("CLAIMED_AMOUNT:", amount);
    }
}
