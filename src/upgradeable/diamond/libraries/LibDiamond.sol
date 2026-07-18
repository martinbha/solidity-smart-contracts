// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDiamond} from "../interfaces/IDiamond.sol";

/// @title LibDiamond
/// @notice The heart of an EIP-2535 diamond: the shared storage layout every
///         facet reaches through, plus the add / replace / remove logic that
///         `diamondCut` executes.
///
///         Facets have no storage of their own — they run via delegatecall in
///         the diamond's context, so a naive `contract Facet { uint x; }`
///         would put `x` at slot 0 of the diamond and collide with the next
///         facet that does the same. The fix is namespaced storage: this
///         library pins its struct at a fixed, collision-resistant slot
///         (`DIAMOND_STORAGE_POSITION`, derived with the ERC-7201 formula) so
///         every facet agrees on exactly where the routing table lives and
///         nothing overlaps by accident.
library LibDiamond {
    /// @dev ERC-7201 namespaced slot:
    ///      keccak256(abi.encode(uint256(keccak256("diamond.standard.diamond.storage")) - 1))
    ///      & ~0xff. The trailing-byte mask keeps the slot clear of the ranges
    ///      the compiler may use for dynamic-array/mapping element hashing.
    bytes32 internal constant DIAMOND_STORAGE_POSITION =
        0x44fefae66705534388ac21ba5f0775616856a675b8eaea9bb0b2507f06238700;

    /// @dev Where a selector lives: which facet serves it, and its index in
    ///      that facet's `functionSelectors` array (for O(1) removal).
    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition;
    }

    /// @dev A facet's selectors, plus that facet's index in `facetAddresses`
    ///      (again for O(1) removal when its last selector is dropped).
    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition;
    }

    struct DiamondStorage {
        // selector => facet + position within that facet's selector array
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        // facet => its selectors + position within facetAddresses
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        // every facet the diamond currently routes to
        address[] facetAddresses;
        // diamond owner — lives here so it survives cuts and every facet sees it
        address contractOwner;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DiamondCut(IDiamond.FacetCut[] cuts, address init, bytes data);

    error NotContractOwner(address caller, address owner);
    error NoSelectorsInFacet();
    error FacetAddressZero();
    error FacetAddressNotZero(address facet);
    error SelectorAlreadyExists(bytes4 selector);
    error ReplaceWithSameFacet(bytes4 selector);
    error SelectorDoesNotExist(bytes4 selector);
    error NoBytecodeAtAddress(address target);
    error InvalidCutAction(uint8 action);
    error InitCallFailed(address init, bytes data);

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    // ─── Ownership ────────────────────────────────────────────────────────────

    function setContractOwner(address newOwner) internal {
        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    function contractOwner() internal view returns (address) {
        return diamondStorage().contractOwner;
    }

    function enforceIsContractOwner() internal view {
        address owner = diamondStorage().contractOwner;
        if (msg.sender != owner) revert NotContractOwner(msg.sender, owner);
    }

    // ─── Cut orchestration ────────────────────────────────────────────────────

    /// @notice Apply a batch of facet cuts, then optionally delegatecall an
    ///         initializer so migrations land atomically with the routing
    ///         changes.
    function diamondCut(IDiamond.FacetCut[] memory cuts, address init, bytes memory data)
        internal
    {
        for (uint256 i = 0; i < cuts.length; i++) {
            bytes4[] memory selectors = cuts[i].functionSelectors;
            address facet = cuts[i].facetAddress;
            if (selectors.length == 0) revert NoSelectorsInFacet();

            IDiamond.FacetCutAction action = cuts[i].action;
            if (action == IDiamond.FacetCutAction.Add) {
                addFunctions(facet, selectors);
            } else if (action == IDiamond.FacetCutAction.Replace) {
                replaceFunctions(facet, selectors);
            } else if (action == IDiamond.FacetCutAction.Remove) {
                removeFunctions(facet, selectors);
            } else {
                revert InvalidCutAction(uint8(action));
            }
        }
        emit DiamondCut(cuts, init, data);
        initializeDiamondCut(init, data);
    }

    function addFunctions(address facet, bytes4[] memory selectors) internal {
        if (facet == address(0)) revert FacetAddressZero();
        DiamondStorage storage ds = diamondStorage();
        enforceHasContractCode(facet);

        uint96 position = uint96(ds.facetFunctionSelectors[facet].functionSelectors.length);
        if (position == 0) addFacet(ds, facet);

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            address existing = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (existing != address(0)) revert SelectorAlreadyExists(selector);
            addFunction(ds, selector, position, facet);
            position++;
        }
    }

    function replaceFunctions(address facet, bytes4[] memory selectors) internal {
        if (facet == address(0)) revert FacetAddressZero();
        DiamondStorage storage ds = diamondStorage();
        enforceHasContractCode(facet);

        uint96 position = uint96(ds.facetFunctionSelectors[facet].functionSelectors.length);
        if (position == 0) addFacet(ds, facet);

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            address old = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (old == address(0)) revert SelectorDoesNotExist(selector);
            if (old == facet) revert ReplaceWithSameFacet(selector);
            removeFunction(ds, old, selector);
            addFunction(ds, selector, position, facet);
            position++;
        }
    }

    function removeFunctions(address facet, bytes4[] memory selectors) internal {
        DiamondStorage storage ds = diamondStorage();
        // Remove instructions target address(0): you are deleting selectors,
        // not pointing them anywhere.
        if (facet != address(0)) revert FacetAddressNotZero(facet);

        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            address old = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (old == address(0)) revert SelectorDoesNotExist(selector);
            removeFunction(ds, old, selector);
        }
    }

    function addFacet(DiamondStorage storage ds, address facet) private {
        ds.facetFunctionSelectors[facet].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(facet);
    }

    function addFunction(
        DiamondStorage storage ds,
        bytes4 selector,
        uint96 position,
        address facet
    ) private {
        ds.selectorToFacetAndPosition[selector].functionSelectorPosition = position;
        ds.facetFunctionSelectors[facet].functionSelectors.push(selector);
        ds.selectorToFacetAndPosition[selector].facetAddress = facet;
    }

    function removeFunction(DiamondStorage storage ds, address facet, bytes4 selector) private {
        // swap-and-pop the selector out of its facet's selector array
        uint256 position = ds.selectorToFacetAndPosition[selector].functionSelectorPosition;
        uint256 lastPosition = ds.facetFunctionSelectors[facet].functionSelectors.length - 1;
        if (position != lastPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[facet].functionSelectors[lastPosition];
            ds.facetFunctionSelectors[facet].functionSelectors[position] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(position);
        }
        ds.facetFunctionSelectors[facet].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[selector];

        // if that was the facet's last selector, swap-and-pop the facet too
        if (lastPosition == 0) {
            uint256 lastFacetPosition = ds.facetAddresses.length - 1;
            uint256 facetPosition = ds.facetFunctionSelectors[facet].facetAddressPosition;
            if (facetPosition != lastFacetPosition) {
                address lastFacet = ds.facetAddresses[lastFacetPosition];
                ds.facetAddresses[facetPosition] = lastFacet;
                ds.facetFunctionSelectors[lastFacet].facetAddressPosition = facetPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[facet].facetAddressPosition;
        }
    }

    // ─── Initialization ───────────────────────────────────────────────────────

    function initializeDiamondCut(address init, bytes memory data) internal {
        if (init == address(0)) return;
        enforceHasContractCode(init);
        (bool success, bytes memory err) = init.delegatecall(data);
        if (!success) {
            if (err.length > 0) {
                // bubble up the initializer's own revert reason
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            revert InitCallFailed(init, data);
        }
    }

    function enforceHasContractCode(address target) internal view {
        if (target.code.length == 0) revert NoBytecodeAtAddress(target);
    }
}
