// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondToken} from "../../src/oracle/BondToken.sol";
import {OptimisticOracle} from "../../src/oracle/OptimisticOracle.sol";

contract OptimisticOracleTest is Test {
    BondToken internal bondToken;
    OptimisticOracle internal oracle;

    address internal resolver = makeAddr("resolver");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant BOND = 100 ether;
    uint40 internal constant CHALLENGE_WINDOW = 1 days;
    bytes32 internal constant CLAIM = keccak256("insured event happened");

    function setUp() public {
        bondToken = new BondToken();
        oracle = new OptimisticOracle(bondToken, resolver, BOND, CHALLENGE_WINDOW);

        bondToken.mint(alice, 1_000 ether);
        bondToken.mint(bob, 1_000 ether);

        vm.prank(alice);
        bondToken.approve(address(oracle), type(uint256).max);
        vm.prank(bob);
        bondToken.approve(address(oracle), type(uint256).max);
    }

    function test_undisputedAssertionSettlesAfterChallengeWindow() public {
        vm.prank(alice);
        oracle.assertTruth(CLAIM, true);

        OptimisticOracle.Assertion memory assertion = oracle.getAssertion(CLAIM);
        assertEq(assertion.asserter, alice);
        assertEq(assertion.deadline, uint40(block.timestamp) + CHALLENGE_WINDOW);
        assertTrue(assertion.assertedValue);
        assertEq(bondToken.balanceOf(address(oracle)), BOND);
        assertEq(oracle.totalEscrowedBonds(), BOND);

        vm.warp(assertion.deadline + 1);
        oracle.settle(CLAIM);

        (bool resolved, bool value) = oracle.getResult(CLAIM);
        assertTrue(resolved);
        assertTrue(value);
        assertEq(oracle.totalEscrowedBonds(), 0);
        assertEq(oracle.withdrawableBonds(alice), BOND);
        assertEq(oracle.totalWithdrawableBonds(), BOND);

        vm.prank(alice);
        oracle.withdrawBond();

        assertEq(bondToken.balanceOf(alice), 1_000 ether);
        assertEq(bondToken.balanceOf(address(oracle)), 0);
        assertEq(oracle.totalWithdrawableBonds(), 0);
    }

    function test_undisputedFalseAssertionSettlesFalse() public {
        vm.prank(alice);
        oracle.assertTruth(CLAIM, false);
        OptimisticOracle.Assertion memory assertion = oracle.getAssertion(CLAIM);

        vm.warp(assertion.deadline + 1);
        oracle.settle(CLAIM);

        (bool resolved, bool value) = oracle.getResult(CLAIM);
        assertTrue(resolved);
        assertFalse(value);
        assertEq(oracle.withdrawableBonds(alice), BOND);
    }

    function test_settlingBeforeChallengeWindowEndsReverts() public {
        vm.prank(alice);
        oracle.assertTruth(CLAIM, true);
        OptimisticOracle.Assertion memory assertion = oracle.getAssertion(CLAIM);

        vm.expectRevert(abi.encodeWithSelector(OptimisticOracle.ChallengeWindowOpen.selector, assertion.deadline));
        oracle.settle(CLAIM);
    }

    function test_duplicateClaimCannotBeAssertedAgain() public {
        vm.prank(alice);
        oracle.assertTruth(CLAIM, true);

        vm.expectRevert(abi.encodeWithSelector(OptimisticOracle.AssertionAlreadyExists.selector, CLAIM));
        vm.prank(bob);
        oracle.assertTruth(CLAIM, false);
    }

    function test_underfundedAssertionCannotPostTheFixedBond() public {
        vm.prank(carol);
        bondToken.approve(address(oracle), type(uint256).max);

        vm.expectRevert();
        vm.prank(carol);
        oracle.assertTruth(CLAIM, true);

        assertEq(oracle.getAssertion(CLAIM).asserter, address(0));
        assertEq(oracle.totalEscrowedBonds(), 0);
    }

    function test_withdrawingWithoutCreditReverts() public {
        vm.expectRevert(OptimisticOracle.NoBondToWithdraw.selector);
        vm.prank(alice);
        oracle.withdrawBond();
    }
}
