// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @title DiamondCutFacet
/// @notice Exposes the one mutating entrypoint of the diamond. It is itself a
///         facet, so the diamond can even upgrade its own upgrade logic — the
///         `diamondCut` selector must be wired in by the very first cut (done
///         in the Diamond constructor) or the diamond becomes immutable.
contract DiamondCutFacet is IDiamondCut {
    /// @inheritdoc IDiamondCut
    function diamondCut(FacetCut[] calldata cuts, address init, bytes calldata data) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(cuts, init, data);
    }
}
