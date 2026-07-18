// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @title DiamondLoupeFacet
/// @notice Read-only introspection over the routing table. A diamond's code is
///         scattered across facets, so these views are the only way a caller
///         (or a block explorer) can discover what the live diamond is made of.
///         Also serves ERC-165 so tooling can detect loupe/cut support.
contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
    /// @inheritdoc IDiamondLoupe
    function facets() external view returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 count = ds.facetAddresses.length;
        facets_ = new Facet[](count);
        for (uint256 i = 0; i < count; i++) {
            address facet = ds.facetAddresses[i];
            facets_[i].facetAddress = facet;
            facets_[i].functionSelectors = ds.facetFunctionSelectors[facet].functionSelectors;
        }
    }

    /// @inheritdoc IDiamondLoupe
    function facetFunctionSelectors(address facet)
        external
        view
        returns (bytes4[] memory)
    {
        return LibDiamond.diamondStorage().facetFunctionSelectors[facet].functionSelectors;
    }

    /// @inheritdoc IDiamondLoupe
    function facetAddresses() external view returns (address[] memory) {
        return LibDiamond.diamondStorage().facetAddresses;
    }

    /// @inheritdoc IDiamondLoupe
    function facetAddress(bytes4 selector) external view returns (address) {
        return LibDiamond.diamondStorage().selectorToFacetAndPosition[selector].facetAddress;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IDiamondLoupe).interfaceId
            || interfaceId == type(IDiamondCut).interfaceId;
    }
}
