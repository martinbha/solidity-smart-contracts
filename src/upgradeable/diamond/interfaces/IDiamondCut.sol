// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDiamond} from "./IDiamond.sol";

/// @title IDiamondCut
/// @notice The single mutating entrypoint of a diamond: add, replace, or
///         remove selectors on a live contract, optionally running an
///         initializer in the diamond's own context in the same transaction.
interface IDiamondCut is IDiamond {
    /// @notice Apply a batch of facet cuts, then (if `init != address(0)`)
    ///         delegatecall `init` with `data` so migrations run atomically
    ///         with the selector changes.
    /// @param cuts The per-facet Add / Replace / Remove instructions.
    /// @param init A contract to delegatecall for initialization, or
    ///        address(0) to skip.
    /// @param data The calldata for that initialization delegatecall.
    function diamondCut(FacetCut[] calldata cuts, address init, bytes calldata data) external;
}
