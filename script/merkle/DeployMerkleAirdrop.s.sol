// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AirdropToken} from "../../src/merkle/AirdropToken.sol";
import {MerkleDistributor} from "../../src/merkle/MerkleDistributor.sol";

/// @notice Deploys the airdrop: token (full supply to deployer), distributor
///         holding the generated tree's root, then funds the distributor with
///         the exact total owed. Requires deployments/merkle/tree.json from
///         GenerateMerkleTree.s.sol.
contract DeployMerkleAirdrop is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 claimWindow = vm.envOr("CLAIM_WINDOW_SECONDS", uint256(30 days));

        string memory treeJson = vm.readFile("deployments/merkle/tree.json");
        bytes32 root = vm.parseJsonBytes32(treeJson, ".root");
        uint256 totalAmount = vm.parseJsonUint(treeJson, ".totalAmount");

        vm.startBroadcast(deployerKey);

        AirdropToken token = new AirdropToken(totalAmount);
        MerkleDistributor distributor = new MerkleDistributor(
            token, root, block.timestamp + claimWindow, vm.addr(deployerKey)
        );
        require(token.transfer(address(distributor), totalAmount), "funding transfer failed");

        vm.stopBroadcast();

        console.log("MERKLE_TOKEN:", address(token));
        console.log("MERKLE_DISTRIBUTOR:", address(distributor));
        console.log("MERKLE_ROOT:", vm.toString(root));
        console.log("FUNDED_AMOUNT:", totalAmount);
        console.log("CLAIM_DEADLINE:", block.timestamp + claimWindow);
    }
}
