// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondToken} from "../../src/oracle/BondToken.sol";
import {OptimisticOracle} from "../../src/oracle/OptimisticOracle.sol";
import {InsurancePool} from "../../src/oracle/InsurancePool.sol";

contract InsurancePoolTest is Test {
    BondToken internal bondToken;
    OptimisticOracle internal oracle;
    InsurancePool internal pool;

    address internal resolver = makeAddr("resolver");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant BOND = 100 ether;
    uint256 internal constant PAYOUT = 500 ether;
    uint40 internal constant CHALLENGE_WINDOW = 1 days;
    bytes32 internal constant CLAIM = keccak256("insured event happened");

    function setUp() public {
        bondToken = new BondToken();
        oracle = new OptimisticOracle(bondToken, resolver, BOND, CHALLENGE_WINDOW);
        pool = new InsurancePool(oracle, bondToken);

        bondToken.mint(alice, 1_000 ether);
        bondToken.mint(address(pool), 1_000 ether);
        vm.prank(alice);
        bondToken.approve(address(oracle), type(uint256).max);

        pool.createPolicy(CLAIM, alice, PAYOUT);
    }

    function _settleUndisputed(bool value) internal {
        vm.prank(alice);
        oracle.assertTruth(CLAIM, value);
        OptimisticOracle.Assertion memory assertion = oracle.getAssertion(CLAIM);
        vm.warp(assertion.deadline + 1);
        oracle.settle(CLAIM);
    }

    function test_resolvedTrueClaimPaysNamedPolicyholder() public {
        _settleUndisputed(true);

        uint256 balanceBefore = bondToken.balanceOf(alice);
        vm.prank(alice);
        pool.claim(CLAIM);

        assertEq(bondToken.balanceOf(alice), balanceBefore + PAYOUT);
        assertEq(bondToken.balanceOf(address(pool)), 1_000 ether - PAYOUT);
        assertTrue(pool.getPolicy(CLAIM).claimed);
    }

    function test_unresolvedClaimCannotTriggerPayout() public {
        vm.prank(alice);
        oracle.assertTruth(CLAIM, true);

        vm.expectRevert(abi.encodeWithSelector(InsurancePool.OracleResultUnresolved.selector, CLAIM));
        vm.prank(alice);
        pool.claim(CLAIM);
    }

    function test_resolvedFalseClaimCannotTriggerPayout() public {
        _settleUndisputed(false);

        vm.expectRevert(abi.encodeWithSelector(InsurancePool.ClaimNotPayable.selector, CLAIM));
        vm.prank(alice);
        pool.claim(CLAIM);
        assertEq(bondToken.balanceOf(address(pool)), 1_000 ether);
    }

    function test_onlyNamedPolicyholderCanClaim() public {
        _settleUndisputed(true);

        vm.expectRevert(abi.encodeWithSelector(InsurancePool.NotBeneficiary.selector, bob, alice));
        vm.prank(bob);
        pool.claim(CLAIM);
    }

    function test_policyCannotPayTwice() public {
        _settleUndisputed(true);
        vm.prank(alice);
        pool.claim(CLAIM);

        vm.expectRevert(abi.encodeWithSelector(InsurancePool.PolicyAlreadyClaimed.selector, CLAIM));
        vm.prank(alice);
        pool.claim(CLAIM);
    }

    function test_onlyPoolOwnerCanCreatePolicies() public {
        bytes32 anotherClaim = keccak256("another event");
        vm.expectRevert(abi.encodeWithSelector(InsurancePool.NotOwner.selector, bob));
        vm.prank(bob);
        pool.createPolicy(anotherClaim, bob, PAYOUT);
    }

    function test_unknownPolicyCannotBeClaimed() public {
        bytes32 unknownClaim = keccak256("unknown event");
        vm.expectRevert(abi.encodeWithSelector(InsurancePool.PolicyNotFound.selector, unknownClaim));
        vm.prank(alice);
        pool.claim(unknownClaim);
    }
}
