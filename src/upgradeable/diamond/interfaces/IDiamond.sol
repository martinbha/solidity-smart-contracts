// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDiamond
/// @notice The core EIP-2535 cut vocabulary shared by the diamond and its
///         cut facet. A cut is a batch of per-facet instructions describing
///         how the diamond's selector table should change.
interface IDiamond {
    /// @notice Add wires brand-new selectors to a facet; Replace re-points
    ///         existing selectors at a different facet; Remove deletes them.
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    /// @param facetAddress The facet a batch of selectors should route to
    ///        (address(0) when removing).
    /// @param action Which of Add / Replace / Remove to apply.
    /// @param functionSelectors The selectors this instruction touches.
    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    /// @notice Emitted for every diamondCut, carrying the full cut plus the
    ///         optional initialization target and calldata.
    event DiamondCut(FacetCut[] cuts, address init, bytes data);
}
