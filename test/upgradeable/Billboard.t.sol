// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Billboard} from "../../src/upgradeable/Billboard.sol";
import {BillboardV2} from "../../src/upgradeable/BillboardV2.sol";

/// @notice V1 behavior: initialization, access control, and proxy hygiene.
contract BillboardTest is Test {
    Billboard internal implementation;
    Billboard internal billboard; // the proxy, viewed through the V1 ABI

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        implementation = new Billboard();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Billboard.initialize, (owner, "gm, world"))
        );
        billboard = Billboard(address(proxy));
    }

    function test_InitialState() public view {
        assertEq(billboard.message(), "gm, world");
        assertEq(billboard.version(), "1");
        assertEq(billboard.owner(), owner);
    }

    function test_SetMessage() public {
        vm.expectEmit();
        emit Billboard.MessageUpdated("wagmi");

        vm.prank(owner);
        billboard.setMessage("wagmi");

        assertEq(billboard.message(), "wagmi");
    }

    function testFuzz_SetMessage(string memory anyMessage) public {
        vm.prank(owner);
        billboard.setMessage(anyMessage);
        assertEq(billboard.message(), anyMessage);
    }

    function test_RevertWhen_SetMessageCalledByStranger() public {
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        billboard.setMessage("graffiti");
    }

    function test_RevertWhen_ProxyInitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        billboard.initialize(stranger, "takeover");
    }

    function test_RevertWhen_ImplementationInitializedDirectly() public {
        // _disableInitializers() in the constructor must have bricked the
        // implementation's own storage against initialization.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(stranger, "hijack");
    }

    function test_RevertWhen_UpgradeCalledByStranger() public {
        BillboardV2 newImplementation = new BillboardV2();

        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        UUPSUpgradeable(address(billboard)).upgradeToAndCall(address(newImplementation), "");
    }
}
