// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibCounter} from "../libraries/LibCounter.sol";

/// @title CounterFacet (V1)
/// @notice A trivial business facet to exercise upgrades. It has no storage of
///         its own — `increment` and `count` reach into the diamond's storage
///         through LibCounter's namespace, so the value they touch survives
///         when this facet is later replaced by a V2.
contract CounterFacet {
    event Incremented(uint256 newCount);

    /// @notice Bump the shared counter by one.
    function increment() external {
        LibCounter.CounterStorage storage cs = LibCounter.counterStorage();
        cs.count += 1;
        emit Incremented(cs.count);
    }

    /// @notice The current counter value.
    function count() external view returns (uint256) {
        return LibCounter.counterStorage().count;
    }
}
