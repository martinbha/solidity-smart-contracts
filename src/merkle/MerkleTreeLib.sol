// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MerkleTreeLib
/// @notice Off-chain tooling: builds the airdrop Merkle tree (root + proofs)
///         inside forge scripts and tests. Never deployed — internal pure
///         functions only. Uses commutative (sorted-pair) hashing so proofs
///         verify with OpenZeppelin's MerkleProof, and promotes unpaired odd
///         nodes to the next level unchanged.
library MerkleTreeLib {
    /// @dev Must mirror MerkleDistributor._claim's leaf construction exactly.
    function leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function buildRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "MerkleTreeLib: no leaves");
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _nextLevel(level);
        }
        return level[0];
    }

    /// @notice Proof for `index` verifying against buildRoot of the same leaves.
    function buildProof(bytes32[] memory leaves, uint256 index)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        require(index < leaves.length, "MerkleTreeLib: index out of range");
        bytes32[] memory scratch = new bytes32[](64); // depth bound: 2^64 leaves
        uint256 count = 0;

        bytes32[] memory level = leaves;
        uint256 position = index;
        while (level.length > 1) {
            uint256 sibling = position ^ 1;
            if (sibling < level.length) {
                scratch[count] = level[sibling];
                count++;
            }
            // No sibling: this node is promoted unchanged, no proof element.
            position /= 2;
            level = _nextLevel(level);
        }

        proof = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            proof[i] = scratch[i];
        }
    }

    function _nextLevel(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        uint256 nextLength = (level.length + 1) / 2;
        next = new bytes32[](nextLength);
        for (uint256 i = 0; i < level.length / 2; i++) {
            next[i] = hashPair(level[2 * i], level[2 * i + 1]);
        }
        if (level.length % 2 == 1) {
            next[nextLength - 1] = level[level.length - 1];
        }
    }
}
