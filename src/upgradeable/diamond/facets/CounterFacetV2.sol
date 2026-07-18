// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibCounter} from "../libraries/LibCounter.sol";

/// @title CounterFacet (V2)
/// @notice The upgrade target for a live `diamondCut`. Replacing V1's selectors
///         with these swaps the counter's behavior — `increment` now steps by
///         a fixed amount and a new `incrementBy` selector is added — while the
///         count itself is untouched, because both versions read and write the
///         same LibCounter slot. That is the whole point of the pattern:
///         upgrade the code, keep the state.
contract CounterFacetV2 {
    /// @notice How much V2's `increment` advances the counter per call.
    uint256 public constant STEP = 5;

    event Incremented(uint256 newCount);

    /// @notice V2 behavior: bump the shared counter by STEP instead of one.
    function increment() external {
        LibCounter.CounterStorage storage cs = LibCounter.counterStorage();
        cs.count += STEP;
        emit Incremented(cs.count);
    }

    /// @notice New in V2: bump the counter by an arbitrary amount.
    function incrementBy(uint256 amount) external {
        LibCounter.CounterStorage storage cs = LibCounter.counterStorage();
        cs.count += amount;
        emit Incremented(cs.count);
    }

    /// @notice The current counter value (unchanged from V1).
    function count() external view returns (uint256) {
        return LibCounter.counterStorage().count;
    }
}
