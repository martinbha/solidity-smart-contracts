// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BondToken} from "../../src/oracle/BondToken.sol";
import {OptimisticOracle} from "../../src/oracle/OptimisticOracle.sol";

contract OptimisticOracleHandler is Test {
    BondToken public bondToken;
    OptimisticOracle public oracle;
    address public resolver;

    address[] public actors;
    bytes32[] public claimIds;
    uint256 private _nextClaim;

    constructor(BondToken bondToken_, OptimisticOracle oracle_, address resolver_) {
        bondToken = bondToken_;
        oracle = oracle_;
        resolver = resolver_;

        actors.push(makeAddr("oracle actor 0"));
        actors.push(makeAddr("oracle actor 1"));
        actors.push(makeAddr("oracle actor 2"));
        actors.push(makeAddr("oracle actor 3"));

        for (uint256 i; i < actors.length; ++i) {
            bondToken.mint(actors[i], 100_000 ether);
            vm.prank(actors[i]);
            bondToken.approve(address(oracle), type(uint256).max);
        }
    }

    function assertTruth(uint256 actorSeed, bool value) external {
        address actor = _actor(actorSeed);
        if (bondToken.balanceOf(actor) < oracle.bondAmount()) return;

        bytes32 claimId = keccak256(abi.encode(_nextClaim++));
        vm.prank(actor);
        oracle.assertTruth(claimId, value);
        claimIds.push(claimId);
    }

    function dispute(uint256 actorSeed, uint256 claimSeed) external {
        if (claimIds.length == 0) return;
        bytes32 claimId = claimIds[claimSeed % claimIds.length];
        OptimisticOracle.Assertion memory assertion = oracle.getAssertion(claimId);
        address actor = _actor(actorSeed);

        if (assertion.resolved || assertion.disputed || actor == assertion.asserter) return;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > assertion.deadline) return;
        if (bondToken.balanceOf(actor) < oracle.bondAmount()) return;

        vm.prank(actor);
        oracle.disputeAssertion(claimId);
    }

    function settle(uint256 claimSeed) external {
        if (claimIds.length == 0) return;
        bytes32 claimId = claimIds[claimSeed % claimIds.length];
        OptimisticOracle.Assertion memory assertion = oracle.getAssertion(claimId);

        if (assertion.resolved || assertion.disputed) return;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= assertion.deadline) return;
        oracle.settle(claimId);
    }

    function resolve(uint256 claimSeed, bool truth) external {
        if (claimIds.length == 0) return;
        bytes32 claimId = claimIds[claimSeed % claimIds.length];
        OptimisticOracle.Assertion memory assertion = oracle.getAssertion(claimId);
        if (assertion.resolved || !assertion.disputed) return;

        vm.prank(resolver);
        oracle.resolve(claimId, truth);
    }

    function withdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (oracle.withdrawableBonds(actor) == 0) return;

        vm.prank(actor);
        oracle.withdrawBond();
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1 hours, 3 days));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }
}

contract OptimisticOracleInvariantTest is Test {
    BondToken internal bondToken;
    OptimisticOracle internal oracle;
    OptimisticOracleHandler internal handler;

    function setUp() public {
        address resolver = makeAddr("resolver");
        bondToken = new BondToken();
        oracle = new OptimisticOracle(bondToken, resolver, 100 ether, 1 days);
        handler = new OptimisticOracleHandler(bondToken, oracle, resolver);
        targetContract(address(handler));
    }

    function invariant_oracleBalanceMatchesEscrowAndCredits() public view {
        assertEq(bondToken.balanceOf(address(oracle)), oracle.accountedBondBalance());
    }

    function invariant_totalBondSupplyIsConserved() public view {
        uint256 accounted = bondToken.balanceOf(address(oracle));
        for (uint256 i; i < handler.actorCount(); ++i) {
            accounted += bondToken.balanceOf(handler.actors(i));
        }
        assertEq(accounted, bondToken.totalSupply());
    }
}
