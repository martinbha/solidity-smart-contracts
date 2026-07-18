// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LibCounter
/// @notice A business facet's namespaced storage, kept deliberately separate
///         from LibDiamond's. Both the counter facets and the diamond's own
///         routing/ownership state live in the SAME contract (the diamond),
///         yet never collide because each pins its struct at its own ERC-7201
///         slot. This is exactly the isolation that makes facet composition
///         safe: add a facet with its own namespace and it cannot corrupt
///         anyone else's slots.
library LibCounter {
    /// @dev keccak256(abi.encode(uint256(keccak256("diamond.counter.storage")) - 1)) & ~0xff
    bytes32 internal constant COUNTER_STORAGE_POSITION =
        0xdb037d86ffd303feaceaef5183785b43243f388a6c78387d18420e8d3589e800;

    struct CounterStorage {
        uint256 count;
    }

    function counterStorage() internal pure returns (CounterStorage storage cs) {
        bytes32 position = COUNTER_STORAGE_POSITION;
        assembly {
            cs.slot := position
        }
    }
}
