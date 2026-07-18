// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDiamond} from "./interfaces/IDiamond.sol";
import {LibDiamond} from "./libraries/LibDiamond.sol";

/// @title Diamond
/// @notice A single proxy that routes each function selector to one of many
///         implementation contracts ("facets"). This lets a logical contract
///         blow past the 24KB runtime code-size limit — the limit is per
///         deployed contract, and a diamond spreads its code across many —
///         and lets you upgrade one function at a time via `diamondCut`.
///
///         The constructor performs the very first cut (which must include a
///         `diamondCut` selector, or the diamond could never be changed
///         again) and sets the owner. Everything else — cutting, introspection,
///         business logic — lives in facets reached through the fallback.
contract Diamond {
    /// @param owner The initial diamond owner (the only address allowed to cut).
    /// @param cuts The initial facet cuts; must wire up a `diamondCut` selector.
    /// @param init A contract to delegatecall for one-time initialization, or
    ///        address(0) to skip.
    /// @param initData The calldata for that initialization delegatecall.
    constructor(
        address owner,
        IDiamond.FacetCut[] memory cuts,
        address init,
        bytes memory initData
    ) payable {
        LibDiamond.setContractOwner(owner);
        LibDiamond.diamondCut(cuts, init, initData);
    }

    /// @notice Routes every call the diamond doesn't itself define to the facet
    ///         registered for `msg.sig`, delegatecalling it so the facet runs
    ///         in this diamond's storage and returns its result verbatim.
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }

        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) revert LibDiamond.SelectorDoesNotExist(msg.sig);

        assembly {
            // copy calldata, delegatecall the facet, return or bubble the revert
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @notice Accept plain ETH transfers (no calldata) without reverting.
    receive() external payable {}
}
