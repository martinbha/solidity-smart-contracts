// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDiamondLoupe
/// @notice The EIP-2535 introspection interface. Because a diamond's real
///         code is scattered across facets, the loupe is the only way to ask
///         a live diamond what it is made of — which facets it has and which
///         selectors each one serves. Tooling and block explorers rely on it.
interface IDiamondLoupe {
    /// @param facetAddress A facet the diamond routes to.
    /// @param functionSelectors Every selector currently served by that facet.
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    /// @notice All facets and the selectors each one serves.
    function facets() external view returns (Facet[] memory);

    /// @notice Every selector served by a single facet.
    function facetFunctionSelectors(address facet)
        external
        view
        returns (bytes4[] memory);

    /// @notice The distinct facet addresses the diamond routes to.
    function facetAddresses() external view returns (address[] memory);

    /// @notice The facet a given selector routes to, or address(0) if none.
    function facetAddress(bytes4 selector) external view returns (address);
}
