// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @title OwnershipFacet
/// @notice Owner read/transfer for the diamond. The owner is stored in diamond
///         storage (via LibDiamond), not in this facet — so it is shared with
///         DiamondCutFacet's authorization check and survives every cut,
///         including one that replaces this very facet.
contract OwnershipFacet {
    /// @notice Hand the diamond to a new owner (only the current owner may).
    function transferOwnership(address newOwner) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(newOwner);
    }

    /// @notice The current diamond owner.
    function owner() external view returns (address) {
        return LibDiamond.contractOwner();
    }
}
