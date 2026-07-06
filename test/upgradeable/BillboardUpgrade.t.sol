// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Billboard} from "../../src/upgradeable/Billboard.sol";
import {BillboardV2} from "../../src/upgradeable/BillboardV2.sol";

/// @notice The upgrade path: V1 -> V2 with state preserved and new features live.
contract BillboardUpgradeTest is Test {
    // ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal proxy;
    address internal owner = makeAddr("owner");

    function setUp() public {
        Billboard implementationV1 = new Billboard();
        proxy = address(
            new ERC1967Proxy(
                address(implementationV1),
                abi.encodeCall(Billboard.initialize, (owner, "carved in stone"))
            )
        );
    }

    function upgradeToV2() internal returns (BillboardV2 newImplementation) {
        newImplementation = new BillboardV2();
        vm.prank(owner);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImplementation), "");
    }

    function test_UpgradeSwapsImplementation() public {
        BillboardV2 newImplementation = upgradeToV2();

        address stored = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        assertEq(stored, address(newImplementation));
        assertEq(BillboardV2(proxy).version(), "2");
    }

    function test_UpgradePreservesV1State() public {
        upgradeToV2();

        assertEq(BillboardV2(proxy).message(), "carved in stone");
        assertEq(BillboardV2(proxy).owner(), owner);
    }

    function test_AppendedStorageStartsZeroed() public {
        upgradeToV2();

        assertEq(BillboardV2(proxy).updateCount(), 0);
        assertEq(BillboardV2(proxy).lastEditor(), address(0));
    }

    function test_V2TracksEdits() public {
        upgradeToV2();

        vm.startPrank(owner);
        BillboardV2(proxy).setMessage("first edit");
        BillboardV2(proxy).setMessage("second edit");
        vm.stopPrank();

        assertEq(BillboardV2(proxy).message(), "second edit");
        assertEq(BillboardV2(proxy).updateCount(), 2);
        assertEq(BillboardV2(proxy).lastEditor(), owner);
    }

    function test_OwnerCanStillUpgradeAfterV2() public {
        // The UUPS footgun check: V2 must retain upgrade capability,
        // otherwise the proxy is bricked forever.
        upgradeToV2();

        BillboardV2 implementationV3 = new BillboardV2();
        vm.prank(owner);
        UUPSUpgradeable(proxy).upgradeToAndCall(address(implementationV3), "");

        address stored = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        assertEq(stored, address(implementationV3));
    }
}
