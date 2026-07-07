// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BeaconBillboard} from "../../../src/upgradeable/beacon/BeaconBillboard.sol";
import {BeaconBillboardV2} from "../../../src/upgradeable/beacon/BeaconBillboardV2.sol";
import {BillboardFactory} from "../../../src/upgradeable/beacon/BillboardFactory.sol";

contract BillboardFleetTest is Test {
    BillboardFactory internal factory;
    BeaconBillboard internal implementationV1;

    address internal fleetAdmin = makeAddr("fleetAdmin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        implementationV1 = new BeaconBillboard();
        factory = new BillboardFactory(address(implementationV1), fleetAdmin);
    }

    function createAs(address creator, string memory msg_, bytes32 salt)
        internal
        returns (address)
    {
        vm.prank(creator);
        return factory.createBillboard(msg_, salt);
    }

    function upgradeFleetToV2() internal returns (BeaconBillboardV2 implementationV2) {
        implementationV2 = new BeaconBillboardV2();
        vm.prank(fleetAdmin);
        factory.upgradeFleet(address(implementationV2));
    }

    // ─── Instance creation ──────────────────────────────────────────────────

    function test_CreateBillboard_CallerBecomesOwner() public {
        address board = createAs(alice, "alice's board", 0);

        assertEq(BeaconBillboard(board).owner(), alice);
        assertEq(BeaconBillboard(board).message(), "alice's board");
        assertEq(BeaconBillboard(board).version(), "1");
        assertEq(factory.billboardCount(), 1);
        assertEq(factory.billboardAt(0), board);
    }

    function test_InstancesHaveIndependentState() public {
        address boardA = createAs(alice, "alice", 0);
        address boardB = createAs(bob, "bob", 0);

        vm.prank(alice);
        BeaconBillboard(boardA).setMessage("alice edited");

        assertEq(BeaconBillboard(boardA).message(), "alice edited");
        assertEq(BeaconBillboard(boardB).message(), "bob"); // untouched
        assertEq(BeaconBillboard(boardB).owner(), bob);
    }

    function test_RevertWhen_StrangerEditsInstance() public {
        address board = createAs(alice, "alice", 0);

        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bob)
        );
        vm.prank(bob);
        BeaconBillboard(board).setMessage("bob's takeover");
    }

    // ─── Deterministic addresses (CREATE2) ──────────────────────────────────

    function test_PredictedAddressMatchesDeployed() public {
        bytes32 salt = keccak256("my board");
        address predicted = factory.predictBillboardAddress(alice, salt, "hello");

        address deployed = createAs(alice, "hello", salt);
        assertEq(deployed, predicted);
    }

    function test_SaltIsCreatorBound() public {
        bytes32 salt = keccak256("shared salt");
        address forAlice = factory.predictBillboardAddress(alice, salt, "hello");
        address forBob = factory.predictBillboardAddress(bob, salt, "hello");
        assertTrue(forAlice != forBob);

        // Bob deploying with Alice's salt cannot land on Alice's address...
        address bobBoard = createAs(bob, "hello", salt);
        assertEq(bobBoard, forBob);

        // ...and Alice's predicted address still deploys fine afterwards.
        address aliceBoard = createAs(alice, "hello", salt);
        assertEq(aliceBoard, forAlice);
    }

    function test_RevertWhen_SameSaltReused() public {
        createAs(alice, "hello", 0);
        vm.expectRevert(); // CREATE2 collision
        createAs(alice, "hello", 0);
    }

    // ─── Fleet upgrade ──────────────────────────────────────────────────────

    function test_OneTransactionUpgradesEveryInstance() public {
        address boardA = createAs(alice, "alice", 0);
        address boardB = createAs(bob, "bob", 0);
        address boardC = createAs(bob, "bob two", bytes32(uint256(1)));

        upgradeFleetToV2();

        assertEq(BeaconBillboardV2(boardA).version(), "2");
        assertEq(BeaconBillboardV2(boardB).version(), "2");
        assertEq(BeaconBillboardV2(boardC).version(), "2");
    }

    function test_StateSurvivesFleetUpgrade() public {
        address boardA = createAs(alice, "carved in stone", 0);
        address boardB = createAs(bob, "bob", 0);

        upgradeFleetToV2();

        assertEq(BeaconBillboardV2(boardA).message(), "carved in stone");
        assertEq(BeaconBillboardV2(boardA).owner(), alice);
        assertEq(BeaconBillboardV2(boardB).message(), "bob");
        assertEq(BeaconBillboardV2(boardB).owner(), bob);
        // V2's appended slots start zeroed on upgraded instances
        assertEq(BeaconBillboardV2(boardA).updateCount(), 0);
        assertEq(BeaconBillboardV2(boardA).lastEditor(), address(0));
    }

    function test_V2FeaturesLiveAfterUpgrade() public {
        address board = createAs(alice, "v1 text", 0);
        upgradeFleetToV2();

        vm.prank(alice);
        BeaconBillboardV2(board).setMessage("v2 text");

        assertEq(BeaconBillboardV2(board).updateCount(), 1);
        assertEq(BeaconBillboardV2(board).lastEditor(), alice);
    }

    function test_InstancesCreatedAfterUpgradeAreV2() public {
        upgradeFleetToV2();

        address board = createAs(alice, "born on v2", 0);
        assertEq(BeaconBillboardV2(board).version(), "2");
        assertEq(BeaconBillboardV2(board).message(), "born on v2");
    }

    function testFuzz_FleetUpgradeCoversAllInstances(uint8 rawCount) public {
        uint256 count = bound(rawCount, 1, 20);
        address[] memory boards = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            boards[i] = createAs(alice, string.concat("board ", vm.toString(i)), bytes32(i));
        }

        upgradeFleetToV2();

        for (uint256 i = 0; i < count; i++) {
            assertEq(BeaconBillboardV2(boards[i]).version(), "2");
            assertEq(
                BeaconBillboardV2(boards[i]).message(), string.concat("board ", vm.toString(i))
            );
        }
    }

    // ─── Upgrade authorization ──────────────────────────────────────────────

    function test_RevertWhen_NonAdminUpgradesFleet() public {
        BeaconBillboardV2 implementationV2 = new BeaconBillboardV2();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        factory.upgradeFleet(address(implementationV2));
    }

    function test_RevertWhen_InstanceOwnerUpgradesBeaconDirectly() public {
        createAs(alice, "alice", 0);
        BeaconBillboardV2 implementationV2 = new BeaconBillboardV2();

        // The beacon is owned by the factory, not the fleet admin and not
        // instance owners — the ONLY upgrade path is factory.upgradeFleet.
        UpgradeableBeacon beacon = factory.beacon();
        assertEq(beacon.owner(), address(factory));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        beacon.upgradeTo(address(implementationV2));

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, fleetAdmin)
        );
        vm.prank(fleetAdmin);
        beacon.upgradeTo(address(implementationV2));
    }

    function test_RevertWhen_ImplementationInitializedDirectly() public {
        vm.expectRevert();
        implementationV1.initialize(alice, "hijack");
    }
}
