// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Diamond} from "../../../src/upgradeable/diamond/Diamond.sol";
import {IDiamond} from "../../../src/upgradeable/diamond/interfaces/IDiamond.sol";
import {DiamondCutFacet} from "../../../src/upgradeable/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../../src/upgradeable/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../../src/upgradeable/diamond/facets/OwnershipFacet.sol";
import {CounterFacet} from "../../../src/upgradeable/diamond/facets/CounterFacet.sol";

/// @notice Deploys the four starter facets and a Diamond wired to all of them
///         in a single initial cut (cut + loupe + ownership + counter). The
///         deploy_diamond.sh script then exercises the counter and performs a
///         live cut that swaps the counter facet for a V2.
contract DeployDiamond is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        CounterFacet counterFacet = new CounterFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](4);
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(cutFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: cutSelectors()
        });
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(loupeFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: loupeSelectors()
        });
        cuts[2] = IDiamond.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: ownershipSelectors()
        });
        cuts[3] = IDiamond.FacetCut({
            facetAddress: address(counterFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: counterSelectors()
        });

        // No initializer needed: the counter starts at zero and the owner is
        // set by the Diamond constructor itself.
        Diamond diamond = new Diamond(owner, cuts, address(0), "");

        vm.stopBroadcast();

        console.log("DIAMOND:", address(diamond));
        console.log("DIAMOND_OWNER:", owner);
        console.log("FACET_CUT:", address(cutFacet));
        console.log("FACET_LOUPE:", address(loupeFacet));
        console.log("FACET_OWNERSHIP:", address(ownershipFacet));
        console.log("FACET_COUNTER:", address(counterFacet));
    }

    function cutSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function loupeSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function ownershipSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }

    function counterSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = CounterFacet.increment.selector;
        s[1] = CounterFacet.count.selector;
    }
}
