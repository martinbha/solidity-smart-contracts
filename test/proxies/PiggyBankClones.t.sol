// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {PiggyBank} from "../../src/proxies/PiggyBank.sol";
import {PiggyBankFactory} from "../../src/proxies/PiggyBankFactory.sol";

contract PiggyBankClonesTest is Test {
    PiggyBankFactory internal factory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint256 internal unlockTime;

    function setUp() public {
        factory = new PiggyBankFactory();
        vm.warp(30 days);
        unlockTime = block.timestamp + 365 days;
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    function _bankFor(address creator, bytes32 salt) internal returns (PiggyBank bank) {
        vm.prank(creator);
        bank = PiggyBank(payable(factory.createBank(unlockTime, salt)));
    }

    // -------------------------------------------------------------- creation

    function test_CloneInitializesWithCallerAsOwner() public {
        PiggyBank bank = _bankFor(alice, "alice-1");
        assertEq(bank.owner(), alice);
        assertEq(bank.unlockTime(), unlockTime);
    }

    function test_SecondInitializeOnCloneReverts() public {
        PiggyBank bank = _bankFor(alice, "alice-1");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(stranger);
        bank.initialize(stranger, 0);
    }

    function test_ImplementationCannotBeInitialized() public {
        PiggyBank impl = PiggyBank(payable(factory.implementation()));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(stranger, 0);
    }

    function test_AllBanksRecordsCreationOrder() public {
        address a = address(_bankFor(alice, "a"));
        address b = address(_bankFor(bob, "b"));
        address[] memory banks = factory.allBanks();
        assertEq(banks.length, 2);
        assertEq(banks[0], a);
        assertEq(banks[1], b);
    }

    // -------------------------------------------------- deterministic addrs

    function test_CloneDeterministicMatchesPrediction() public {
        bytes32 salt = "my-piggy";
        address predicted = factory.predictBankAddress(alice, salt);
        assertEq(predicted.code.length, 0);

        PiggyBank bank = _bankFor(alice, salt);
        assertEq(address(bank), predicted);
        assertGt(predicted.code.length, 0);
    }

    function test_SaltReuseBySameCreatorReverts() public {
        _bankFor(alice, "same-salt");
        vm.expectRevert(Errors.FailedDeployment.selector);
        vm.prank(alice);
        factory.createBank(unlockTime, "same-salt");
    }

    function test_SameSaltDifferentCreatorsDoNotCollide() public {
        PiggyBank bankA = _bankFor(alice, "same-salt");
        PiggyBank bankB = _bankFor(bob, "same-salt");
        assertTrue(address(bankA) != address(bankB));
        assertEq(bankA.owner(), alice);
        assertEq(bankB.owner(), bob);
    }

    // ------------------------------------------------------------ isolation

    function test_ClonesHaveIndependentState() public {
        PiggyBank bankA = _bankFor(alice, "a");

        uint256 laterUnlock = unlockTime + 30 days;
        vm.prank(bob);
        PiggyBank bankB = PiggyBank(payable(factory.createBank(laterUnlock, "b")));

        vm.prank(alice);
        (bool okA,) = address(bankA).call{value: 3 ether}("");
        vm.prank(bob);
        (bool okB,) = address(bankB).call{value: 5 ether}("");
        assertTrue(okA && okB);

        assertEq(address(bankA).balance, 3 ether);
        assertEq(address(bankB).balance, 5 ether);
        assertEq(bankA.owner(), alice);
        assertEq(bankB.owner(), bob);
        assertEq(bankA.unlockTime(), unlockTime);
        assertEq(bankB.unlockTime(), laterUnlock);

        // Draining A after its unlock leaves B untouched (and still locked).
        vm.warp(unlockTime);
        vm.prank(alice);
        bankA.withdraw();
        assertEq(address(bankA).balance, 0);
        assertEq(address(bankB).balance, 5 ether);
    }

    function test_WithdrawBeforeUnlockReverts() public {
        PiggyBank bank = _bankFor(alice, "a");
        vm.warp(unlockTime - 1);
        vm.expectRevert(abi.encodeWithSelector(PiggyBank.StillLocked.selector, unlockTime, unlockTime - 1));
        vm.prank(alice);
        bank.withdraw();
    }

    function test_StrangerWithdrawReverts() public {
        PiggyBank bank = _bankFor(alice, "a");
        vm.warp(unlockTime);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        bank.withdraw();
    }

    function test_PastUnlockTimeIsImmediatelyWithdrawable() public {
        vm.prank(alice);
        PiggyBank bank = PiggyBank(payable(factory.createBank(block.timestamp - 1, "past")));
        vm.prank(bob);
        (bool ok,) = address(bank).call{value: 1 ether}("");
        assertTrue(ok);

        uint256 before = alice.balance;
        vm.prank(alice);
        bank.withdraw();
        assertEq(alice.balance - before, 1 ether);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Conservation across the whole fleet: whatever lands in N clones
    ///      comes back out to their owners in full, with no clone able to
    ///      touch another's balance.
    function testFuzz_TotalEthConservedAcrossClones(uint256[8] memory depositSeeds) public {
        uint256 total;
        address[8] memory owners;
        PiggyBank[8] memory banks;

        for (uint256 i = 0; i < 8; i++) {
            owners[i] = makeAddr(string(abi.encodePacked("owner", i)));
            vm.deal(owners[i], 11 ether);
            vm.prank(owners[i]);
            banks[i] = PiggyBank(payable(factory.createBank(unlockTime, bytes32(i))));

            uint256 amount = bound(depositSeeds[i], 0, 10 ether);
            total += amount;
            if (amount > 0) {
                vm.prank(owners[i]);
                (bool ok,) = address(banks[i]).call{value: amount}("");
                assertTrue(ok);
            }
        }

        vm.warp(unlockTime);
        uint256 paidOut;
        for (uint256 i = 0; i < 8; i++) {
            uint256 before = owners[i].balance;
            vm.prank(owners[i]);
            banks[i].withdraw();
            paidOut += owners[i].balance - before;
            assertEq(address(banks[i]).balance, 0);
        }
        assertEq(paidOut, total, "ETH not conserved across clone fleet");
    }

    // ------------------------------------------------------------------- gas

    /// @dev The cost triangle, printed with -vv. Deploy cost: clone is ~10x
    ///      cheaper than `new` and ~4x cheaper than a BeaconProxy. Per-call:
    ///      direct is cheapest, clone pays one delegatecall hop, beacon pays
    ///      the hop plus a beacon staticcall to resolve the implementation.
    function test_GasTriangle_DeployAndPerCall() public {
        address impl = factory.implementation();

        // --- deploy costs ---------------------------------------------
        uint256 g = gasleft();
        PiggyBank direct = new PiggyBank();
        uint256 gasNew = g - gasleft();

        g = gasleft();
        address rawClone = Clones.clone(impl);
        uint256 gasClone = g - gasleft();

        UpgradeableBeacon beacon = new UpgradeableBeacon(impl, address(this));
        g = gasleft();
        BeaconProxy beaconProxy =
            new BeaconProxy(address(beacon), abi.encodeCall(PiggyBank.initialize, (address(this), unlockTime)));
        uint256 gasBeacon = g - gasleft();

        console.log("deploy gas:");
        console.log("  new PiggyBank():        %s", gasNew);
        console.log("  ERC-1167 clone:         %s", gasClone);
        console.log("  BeaconProxy (init'd):   %s", gasBeacon);

        assertLt(gasClone, gasNew / 5, "clone should be far cheaper than new");
        assertLt(gasClone, gasBeacon / 5, "clone should be far cheaper than beacon proxy");

        // --- per-call overhead (a plain ETH deposit through each) ------
        PiggyBank(payable(rawClone)).initialize(address(this), unlockTime);

        g = gasleft();
        (bool ok1,) = address(direct).call{value: 1 ether}("");
        uint256 callDirect = g - gasleft();

        g = gasleft();
        (bool ok2,) = rawClone.call{value: 1 ether}("");
        uint256 callClone = g - gasleft();

        g = gasleft();
        (bool ok3,) = address(beaconProxy).call{value: 1 ether}("");
        uint256 callBeacon = g - gasleft();
        assertTrue(ok1 && ok2 && ok3);

        console.log("per-call gas (ETH deposit):");
        console.log("  direct:                 %s", callDirect);
        console.log("  through clone:          %s", callClone);
        console.log("  through beacon proxy:   %s", callBeacon);

        assertGt(callClone, callDirect, "clone adds a delegatecall hop");
        assertGt(callBeacon, callClone, "beacon adds an implementation lookup on top");
    }

    /// @dev Fund the gas test's deposits and receive nothing else.
    receive() external payable {}
}
