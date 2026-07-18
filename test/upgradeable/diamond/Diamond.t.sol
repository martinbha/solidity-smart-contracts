// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Diamond} from "../../../src/upgradeable/diamond/Diamond.sol";
import {IDiamond} from "../../../src/upgradeable/diamond/interfaces/IDiamond.sol";
import {IDiamondCut} from "../../../src/upgradeable/diamond/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../../src/upgradeable/diamond/interfaces/IDiamondLoupe.sol";
import {LibDiamond} from "../../../src/upgradeable/diamond/libraries/LibDiamond.sol";
import {DiamondCutFacet} from "../../../src/upgradeable/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../../src/upgradeable/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../../src/upgradeable/diamond/facets/OwnershipFacet.sol";
import {CounterFacet} from "../../../src/upgradeable/diamond/facets/CounterFacet.sol";
import {CounterFacetV2} from "../../../src/upgradeable/diamond/facets/CounterFacetV2.sol";

contract DiamondTest is Test {
    Diamond internal diamond;

    // The diamond, viewed through each facet's interface.
    IDiamondCut internal cut;
    IDiamondLoupe internal loupe;
    OwnershipFacet internal ownership;
    CounterFacet internal counter;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    // Kept so tests can address the deployed facets directly.
    DiamondCutFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    OwnershipFacet internal ownershipFacet;
    CounterFacet internal counterFacet;

    function setUp() public {
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        counterFacet = new CounterFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](4);
        cuts[0] = _cut(address(cutFacet), IDiamond.FacetCutAction.Add, _cutSelectors());
        cuts[1] = _cut(address(loupeFacet), IDiamond.FacetCutAction.Add, _loupeSelectors());
        cuts[2] = _cut(address(ownershipFacet), IDiamond.FacetCutAction.Add, _ownershipSelectors());
        cuts[3] = _cut(address(counterFacet), IDiamond.FacetCutAction.Add, _counterSelectors());

        diamond = new Diamond(owner, cuts, address(0), "");

        cut = IDiamondCut(address(diamond));
        loupe = IDiamondLoupe(address(diamond));
        ownership = OwnershipFacet(address(diamond));
        counter = CounterFacet(address(diamond));
    }

    // ─── Routing ──────────────────────────────────────────────────────────────

    function test_CallsRouteToCorrectFacet() public {
        assertEq(counter.count(), 0);
        counter.increment();
        counter.increment();
        assertEq(counter.count(), 2);
        assertEq(ownership.owner(), owner);
    }

    function test_RevertWhen_UnknownSelectorCalled() public {
        // A selector no facet serves must revert cleanly, not silently succeed.
        bytes memory callData = abi.encodeWithSelector(bytes4(0xdeadbeef));
        vm.expectRevert(
            abi.encodeWithSelector(LibDiamond.SelectorDoesNotExist.selector, bytes4(0xdeadbeef))
        );
        _mustCall(address(diamond), callData);
    }

    // ─── Cut: Add / Replace / Remove ────────────────────────────────────────────

    function test_Add_ExposesNewSelector() public {
        CounterFacetV2 v2 = new CounterFacetV2();
        bytes4[] memory sel = _one(CounterFacetV2.incrementBy.selector);

        // incrementBy does not exist yet.
        (bool okBefore,) =
            address(diamond).call(abi.encodeCall(CounterFacetV2.incrementBy, (3)));
        assertFalse(okBefore);

        _applyCut(address(v2), IDiamond.FacetCutAction.Add, sel);

        CounterFacetV2(address(diamond)).incrementBy(3);
        assertEq(counter.count(), 3);
        assertEq(loupe.facetAddress(CounterFacetV2.incrementBy.selector), address(v2));
    }

    function test_Replace_SwapsBehaviorButKeepsStorage() public {
        counter.increment();
        counter.increment();
        counter.increment();
        assertEq(counter.count(), 3);

        CounterFacetV2 v2 = new CounterFacetV2();
        _applyCut(address(v2), IDiamond.FacetCutAction.Replace, _one(CounterFacet.increment.selector));

        // Same selector, new behavior: steps by 5 now.
        CounterFacetV2(address(diamond)).increment();
        // ...and the pre-existing value survived the swap.
        assertEq(counter.count(), 8);
        assertEq(loupe.facetAddress(CounterFacet.increment.selector), address(v2));
    }

    function test_Remove_MakesSelectorRevert() public {
        _applyCut(address(0), IDiamond.FacetCutAction.Remove, _one(CounterFacet.increment.selector));

        assertEq(loupe.facetAddress(CounterFacet.increment.selector), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                LibDiamond.SelectorDoesNotExist.selector, CounterFacet.increment.selector
            )
        );
        _mustCall(address(diamond), abi.encodeCall(CounterFacet.increment, ()));

        // count() was not removed, so it still routes.
        assertEq(counter.count(), 0);
    }

    // ─── Loupe ──────────────────────────────────────────────────────────────────

    function test_Loupe_EnumeratesFacetsAndSelectors() public view {
        address[] memory addrs = loupe.facetAddresses();
        assertEq(addrs.length, 4);

        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        assertEq(facets.length, 4);

        // Every selector each facet lists must route back to that same facet.
        uint256 totalSelectors;
        for (uint256 i = 0; i < facets.length; i++) {
            bytes4[] memory sels = facets[i].functionSelectors;
            totalSelectors += sels.length;
            for (uint256 j = 0; j < sels.length; j++) {
                assertEq(loupe.facetAddress(sels[j]), facets[i].facetAddress);
            }
        }
        // 1 cut + 5 loupe + 2 ownership + 2 counter.
        assertEq(totalSelectors, 10);

        assertEq(
            loupe.facetFunctionSelectors(address(counterFacet)).length, 2
        );
    }

    function test_Loupe_ReflectsCutsAfterReplace() public {
        CounterFacetV2 v2 = new CounterFacetV2();
        // Fully migrate the counter to V2: replace both selectors, add one.
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](2);
        bytes4[] memory replaced = new bytes4[](2);
        replaced[0] = CounterFacet.increment.selector;
        replaced[1] = CounterFacet.count.selector;
        cuts[0] = _cut(address(v2), IDiamond.FacetCutAction.Replace, replaced);
        cuts[1] = _cut(address(v2), IDiamond.FacetCutAction.Add, _one(CounterFacetV2.incrementBy.selector));

        vm.prank(owner);
        cut.diamondCut(cuts, address(0), "");

        // The old counter facet has no selectors left, so it drops out.
        address[] memory addrs = loupe.facetAddresses();
        for (uint256 i = 0; i < addrs.length; i++) {
            assertTrue(addrs[i] != address(counterFacet));
        }
        assertEq(loupe.facetFunctionSelectors(address(counterFacet)).length, 0);
        assertEq(loupe.facetFunctionSelectors(address(v2)).length, 3);
    }

    function test_Loupe_SupportsInterface() public view {
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertFalse(IERC165(address(diamond)).supportsInterface(bytes4(0xffffffff)));
    }

    // ─── Ownership ──────────────────────────────────────────────────────────────

    function test_RevertWhen_NonOwnerCuts() public {
        CounterFacetV2 v2 = new CounterFacetV2();
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](1);
        cuts[0] = _cut(address(v2), IDiamond.FacetCutAction.Add, _one(CounterFacetV2.incrementBy.selector));

        vm.expectRevert(
            abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, stranger, owner)
        );
        vm.prank(stranger);
        cut.diamondCut(cuts, address(0), "");
    }

    function test_OwnershipLivesInDiamondStorageAndSurvivesCuts() public {
        // Transfer ownership, then perform a cut, and confirm the new owner
        // (stored in diamond storage) both took effect and persisted.
        vm.prank(owner);
        ownership.transferOwnership(stranger);
        assertEq(ownership.owner(), stranger);

        CounterFacetV2 v2 = new CounterFacetV2();
        _applyCutAs(stranger, address(v2), IDiamond.FacetCutAction.Add, _one(CounterFacetV2.incrementBy.selector));

        assertEq(ownership.owner(), stranger);
    }

    function test_RevertWhen_NonOwnerTransfersOwnership() public {
        vm.expectRevert(
            abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, stranger, owner)
        );
        vm.prank(stranger);
        ownership.transferOwnership(stranger);
    }

    function test_OwnershipSurvivesReplacingItsOwnFacet() public {
        // Replace the OwnershipFacet with a fresh instance; the owner value,
        // living in diamond storage rather than the facet, is unaffected.
        OwnershipFacet newOwnershipFacet = new OwnershipFacet();
        _applyCut(address(newOwnershipFacet), IDiamond.FacetCutAction.Replace, _ownershipSelectors());

        assertEq(ownership.owner(), owner);
        assertEq(loupe.facetAddress(OwnershipFacet.owner.selector), address(newOwnershipFacet));
    }

    // ─── Storage isolation ──────────────────────────────────────────────────────

    function test_FacetsWithSeparateNamespacesDoNotCollide() public {
        // The counter (LibCounter namespace) and the owner (LibDiamond
        // namespace) share the diamond's storage but must never corrupt each
        // other, no matter how they interleave.
        counter.increment();
        vm.prank(owner);
        ownership.transferOwnership(stranger);
        counter.increment();

        assertEq(counter.count(), 2);
        assertEq(ownership.owner(), stranger);

        vm.prank(stranger);
        ownership.transferOwnership(owner);
        assertEq(counter.count(), 2); // ownership churn left the counter alone
        assertEq(ownership.owner(), owner);
    }

    // ─── Cut validation ───────────────────────────────────────────────────────

    function test_RevertWhen_AddingExistingSelector() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LibDiamond.SelectorAlreadyExists.selector, CounterFacet.increment.selector
            )
        );
        _applyCut(address(counterFacet), IDiamond.FacetCutAction.Add, _one(CounterFacet.increment.selector));
    }

    function test_RevertWhen_RemovingNonexistentSelector() public {
        vm.expectRevert(
            abi.encodeWithSelector(LibDiamond.SelectorDoesNotExist.selector, bytes4(0xdeadbeef))
        );
        _applyCut(address(0), IDiamond.FacetCutAction.Remove, _one(bytes4(0xdeadbeef)));
    }

    function test_RevertWhen_ReplacingWithSameFacet() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LibDiamond.ReplaceWithSameFacet.selector, CounterFacet.increment.selector
            )
        );
        _applyCut(address(counterFacet), IDiamond.FacetCutAction.Replace, _one(CounterFacet.increment.selector));
    }

    function test_RevertWhen_AddingToAddressWithoutCode() public {
        vm.expectRevert(
            abi.encodeWithSelector(LibDiamond.NoBytecodeAtAddress.selector, address(0xBEEF))
        );
        _applyCut(address(0xBEEF), IDiamond.FacetCutAction.Add, _one(bytes4(0x12345678)));
    }

    function test_RevertWhen_RemoveTargetsNonZeroFacet() public {
        vm.expectRevert(
            abi.encodeWithSelector(LibDiamond.FacetAddressNotZero.selector, address(counterFacet))
        );
        _applyCut(address(counterFacet), IDiamond.FacetCutAction.Remove, _one(CounterFacet.increment.selector));
    }

    // ─── Fuzz: routing stays consistent with the loupe ──────────────────────────

    function testFuzz_RandomCutsKeepLoupeConsistentWithRouting(
        uint8 replaceMask,
        uint8 removeMask
    ) public {
        PingFacetA a = new PingFacetA();
        PingFacetB b = new PingFacetB();
        uint256 n = a.selectorCount();

        // Add all ping selectors to facet A.
        _applyCut(address(a), IDiamond.FacetCutAction.Add, a.selectors());

        // Replace a fuzzed subset onto B.
        bytes4[] memory toReplace = _masked(a.selectors(), replaceMask);
        if (toReplace.length > 0) {
            _applyCut(address(b), IDiamond.FacetCutAction.Replace, toReplace);
        }

        // Remove a fuzzed subset (of whatever currently exists).
        bytes4[] memory toRemove = _masked(a.selectors(), removeMask);
        if (toRemove.length > 0) {
            _applyCut(address(0), IDiamond.FacetCutAction.Remove, toRemove);
        }

        // Build the expected routing model and check the diamond against it.
        for (uint256 i = 0; i < n; i++) {
            bytes4 sel = a.selectors()[i];
            bool removed = _bit(removeMask, i);
            bool replaced = _bit(replaceMask, i);

            if (removed) {
                assertEq(loupe.facetAddress(sel), address(0));
                (bool ok,) = address(diamond).call(abi.encodeWithSelector(sel));
                assertFalse(ok);
            } else {
                address expected = replaced ? address(b) : address(a);
                assertEq(loupe.facetAddress(sel), expected);
                (bool ok, bytes memory ret) = address(diamond).call(abi.encodeWithSelector(sel));
                assertTrue(ok);
                // A returns 100+i, B returns 200+i — proves routing, not just registration.
                uint256 marker = replaced ? 200 + i : 100 + i;
                assertEq(abi.decode(ret, (uint256)), marker);
            }
        }

        // The loupe's own enumeration must agree with per-selector routing.
        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        for (uint256 i = 0; i < facets.length; i++) {
            for (uint256 j = 0; j < facets[i].functionSelectors.length; j++) {
                assertEq(loupe.facetAddress(facets[i].functionSelectors[j]), facets[i].facetAddress);
            }
        }
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────

    function _applyCut(address facet, IDiamond.FacetCutAction action, bytes4[] memory selectors)
        internal
    {
        _applyCutAs(owner, facet, action, selectors);
    }

    function _applyCutAs(
        address as_,
        address facet,
        IDiamond.FacetCutAction action,
        bytes4[] memory selectors
    ) internal {
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](1);
        cuts[0] = _cut(facet, action, selectors);
        vm.prank(as_);
        cut.diamondCut(cuts, address(0), "");
    }

    function _cut(address facet, IDiamond.FacetCutAction action, bytes4[] memory selectors)
        internal
        pure
        returns (IDiamond.FacetCut memory)
    {
        return IDiamond.FacetCut({
            facetAddress: facet,
            action: action,
            functionSelectors: selectors
        });
    }

    /// @dev Reverts with the callee's revert data if the call fails, so
    ///      expectRevert can match the diamond's fallback revert.
    function _mustCall(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _one(bytes4 selector) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = selector;
    }

    function _masked(bytes4[] memory all, uint8 mask) internal pure returns (bytes4[] memory out) {
        uint256 count;
        for (uint256 i = 0; i < all.length; i++) {
            if (_bit(mask, i)) count++;
        }
        out = new bytes4[](count);
        uint256 k;
        for (uint256 i = 0; i < all.length; i++) {
            if (_bit(mask, i)) out[k++] = all[i];
        }
    }

    function _bit(uint8 mask, uint256 i) internal pure returns (bool) {
        return (mask >> i) & 1 == 1;
    }

    function _cutSelectors() internal pure returns (bytes4[] memory s) {
        s = _one(DiamondCutFacet.diamondCut.selector);
    }

    function _loupeSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _ownershipSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }

    function _counterSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = CounterFacet.increment.selector;
        s[1] = CounterFacet.count.selector;
    }
}

/// @dev Test-only facet whose five ping functions each return 100 + index, so
///      a call through the diamond proves which facet actually ran.
contract PingFacetA {
    function ping0() external pure returns (uint256) {
        return 100;
    }

    function ping1() external pure returns (uint256) {
        return 101;
    }

    function ping2() external pure returns (uint256) {
        return 102;
    }

    function ping3() external pure returns (uint256) {
        return 103;
    }

    function ping4() external pure returns (uint256) {
        return 104;
    }

    function selectorCount() external pure returns (uint256) {
        return 5;
    }

    function selectors() external pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = this.ping0.selector;
        s[1] = this.ping1.selector;
        s[2] = this.ping2.selector;
        s[3] = this.ping3.selector;
        s[4] = this.ping4.selector;
    }
}

/// @dev Same selectors as PingFacetA, returning 200 + index instead.
contract PingFacetB {
    function ping0() external pure returns (uint256) {
        return 200;
    }

    function ping1() external pure returns (uint256) {
        return 201;
    }

    function ping2() external pure returns (uint256) {
        return 202;
    }

    function ping3() external pure returns (uint256) {
        return 203;
    }

    function ping4() external pure returns (uint256) {
        return 204;
    }
}
