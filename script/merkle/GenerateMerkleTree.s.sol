// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MerkleTreeLib} from "../../src/merkle/MerkleTreeLib.sol";

/// @notice Off-chain tree generation — no transactions, pure file I/O.
///         Reads utils/merkle/recipients.json ([{account, amount}, ...]),
///         builds the Merkle tree, and writes deployments/merkle/tree.json
///         with the root plus a proof for every claim. The chain will only
///         ever see the 32-byte root; this file is how recipients get their
///         proofs.
contract GenerateMerkleTree is Script {
    // Fields must be alphabetical for vm.parseJson struct decoding.
    struct Recipient {
        address account;
        uint256 amount;
    }

    function run() external {
        string memory inputJson = vm.readFile("utils/merkle/recipients.json");
        Recipient[] memory recipients = abi.decode(vm.parseJson(inputJson), (Recipient[]));
        require(recipients.length > 0, "no recipients");

        bytes32[] memory leaves = new bytes32[](recipients.length);
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            leaves[i] = MerkleTreeLib.leaf(i, recipients[i].account, recipients[i].amount);
            totalAmount += recipients[i].amount;
        }
        bytes32 root = MerkleTreeLib.buildRoot(leaves);

        // Build tree.json by hand: forge's serializeString escapes nested
        // objects, so manual concatenation is the robust path.
        string memory claims = "";
        for (uint256 i = 0; i < recipients.length; i++) {
            bytes32[] memory proof = MerkleTreeLib.buildProof(leaves, i);
            string memory proofJson = "";
            for (uint256 j = 0; j < proof.length; j++) {
                proofJson = string.concat(
                    proofJson, j == 0 ? "" : ",", "\"", vm.toString(proof[j]), "\""
                );
            }
            claims = string.concat(
                claims,
                i == 0 ? "" : ",",
                "{\"index\":", vm.toString(i),
                ",\"account\":\"", vm.toString(recipients[i].account),
                "\",\"amount\":\"", vm.toString(recipients[i].amount),
                "\",\"proof\":[", proofJson, "]}"
            );
        }
        string memory treeJson = string.concat(
            "{\"root\":\"", vm.toString(root),
            "\",\"count\":", vm.toString(recipients.length),
            ",\"totalAmount\":\"", vm.toString(totalAmount),
            "\",\"claims\":[", claims, "]}"
        );

        vm.writeFile("deployments/merkle/tree.json", treeJson);

        console.log("MERKLE_ROOT:", vm.toString(root));
        console.log("RECIPIENT_COUNT:", recipients.length);
        console.log("TOTAL_AMOUNT:", totalAmount);
        console.log("written to deployments/merkle/tree.json");
    }
}
