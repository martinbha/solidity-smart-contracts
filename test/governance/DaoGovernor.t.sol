// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GovToken} from "../../src/governance/GovToken.sol";
import {DaoGovernor} from "../../src/governance/DaoGovernor.sol";
import {Treasury} from "../../src/governance/Treasury.sol";

contract DaoGovernorTest is Test {
    uint256 internal constant MIN_DELAY = 2 days;
    uint8 internal constant VOTE_AGAINST = 0;
    uint8 internal constant VOTE_FOR = 1;

    GovToken internal token;
    TimelockController internal timelock;
    DaoGovernor internal governor;
    Treasury internal treasury;

    // 1000 GOV total; 4% quorum = 40 GOV. Carol alone cannot reach it.
    address internal alice = makeAddr("alice"); // 600 GOV
    address internal bob = makeAddr("bob"); // 370 GOV
    address internal carol = makeAddr("carol"); // 30 GOV
    address internal recipient = makeAddr("recipient");

    string internal constant DESCRIPTION = "Pay the recipient a 10 ETH grant";

    function setUp() public {
        token = new GovToken();
        timelock = new TimelockController(MIN_DELAY, new address[](0), new address[](0), address(this));
        governor = new DaoGovernor(token, timelock);

        // The canonical wiring: the Governor is the only proposer/canceller,
        // anyone may execute a ready operation, and the deployer walks away
        // from the admin role so no single key can bypass governance.
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        treasury = new Treasury(address(timelock));
        vm.deal(address(treasury), 100 ether);

        _mintAndDelegate(alice, 600 ether);
        _mintAndDelegate(bob, 370 ether);
        _mintAndDelegate(carol, 30 ether);

        // Checkpoints are read strictly before the snapshot block; move past
        // the block that recorded the delegations.
        vm.roll(block.number + 1);
    }

    // ---------------------------------------------------------------- helpers

    function _mintAndDelegate(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.delegate(who);
    }

    function _payout(uint256 amount)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(treasury);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(Treasury.release, (payable(recipient), amount));
    }

    function _propose(uint256 amount) internal returns (uint256 proposalId) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _payout(amount);
        vm.prank(alice);
        proposalId = governor.propose(targets, values, calldatas, DESCRIPTION);
    }

    function _rollToActive(uint256 proposalId) internal {
        vm.roll(governor.proposalSnapshot(proposalId) + 1);
    }

    function _rollPastDeadline(uint256 proposalId) internal {
        vm.roll(governor.proposalDeadline(proposalId) + 1);
    }

    function _queue(uint256 amount) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _payout(amount);
        governor.queue(targets, values, calldatas, keccak256(bytes(DESCRIPTION)));
    }

    function _execute(uint256 amount) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _payout(amount);
        governor.execute(targets, values, calldatas, keccak256(bytes(DESCRIPTION)));
    }

    function _stateBitmap(IGovernor.ProposalState s) internal pure returns (bytes32) {
        return bytes32(uint256(1 << uint8(s)));
    }

    // ---------------------------------------------------------- full lifecycle

    function test_fullLifecycleMovesTreasuryFundsExactlyAsEncoded() public {
        uint256 proposalId = _propose(10 ether);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        _rollToActive(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        vm.prank(alice);
        governor.castVote(proposalId, VOTE_FOR);
        vm.prank(bob);
        governor.castVote(proposalId, VOTE_AGAINST);

        _rollPastDeadline(proposalId);
        // 600 For > 370 Against, and quorum (40) is met.
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        _queue(10 ether);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        vm.warp(block.timestamp + MIN_DELAY + 1);
        _execute(10 ether);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        assertEq(recipient.balance, 10 ether);
        assertEq(address(treasury).balance, 90 ether);
    }

    // -------------------------------------------------------------- delegation

    function test_undelegatedTokensCarryNoVotingPower() public {
        address dave = makeAddr("dave");
        token.mint(dave, 500 ether); // never delegated
        vm.roll(block.number + 1);

        uint256 proposalId = _propose(10 ether);
        _rollToActive(proposalId);

        vm.prank(dave);
        governor.castVote(proposalId, VOTE_FOR);

        // The vote was accepted but weighed nothing.
        assertTrue(governor.hasVoted(proposalId, dave));
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 0);
    }

    function test_delegationActivatesVotingPowerGoingForward() public {
        address dave = makeAddr("dave");
        token.mint(dave, 500 ether);
        assertEq(token.getVotes(dave), 0);

        vm.prank(dave);
        token.delegate(dave);
        assertEq(token.getVotes(dave), 500 ether);
        vm.roll(block.number + 1);

        // On a proposal snapshotted after the delegation, the power counts.
        uint256 proposalId = _propose(10 ether);
        _rollToActive(proposalId);
        vm.prank(dave);
        governor.castVote(proposalId, VOTE_FOR);

        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 500 ether);
    }

    // ------------------------------------------------------------------ quorum

    function test_proposalBelowQuorumIsDefeatedAndCannotBeQueued() public {
        uint256 proposalId = _propose(10 ether);
        _rollToActive(proposalId);

        // Carol's 30 GOV is below the 40 GOV quorum (4% of 1000).
        vm.prank(carol);
        governor.castVote(proposalId, VOTE_FOR);

        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _payout(10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Defeated,
                _stateBitmap(IGovernor.ProposalState.Succeeded)
            )
        );
        governor.queue(targets, values, calldatas, keccak256(bytes(DESCRIPTION)));
    }

    // ----------------------------------------------------------- voting window

    function test_votingBeforeTheDelayReverts() public {
        uint256 proposalId = _propose(10 ether);

        // Still Pending: the snapshot block has not been reached.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Pending,
                _stateBitmap(IGovernor.ProposalState.Active)
            )
        );
        governor.castVote(proposalId, VOTE_FOR);
    }

    function test_votingAfterThePeriodReverts() public {
        uint256 proposalId = _propose(10 ether);
        _rollToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, VOTE_FOR);
        _rollPastDeadline(proposalId);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Succeeded,
                _stateBitmap(IGovernor.ProposalState.Active)
            )
        );
        governor.castVote(proposalId, VOTE_FOR);
    }

    // -------------------------------------------------------------- timelock

    function test_executionBeforeTheTimelockElapsesReverts() public {
        uint256 proposalId = _propose(10 ether);
        _rollToActive(proposalId);
        vm.prank(alice);
        governor.castVote(proposalId, VOTE_FOR);
        _rollPastDeadline(proposalId);
        _queue(10 ether);

        // The timelock knows the operation but it is Waiting, not Ready.
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _payout(10 ether);
        bytes32 salt = bytes20(address(governor)) ^ keccak256(bytes(DESCRIPTION));
        bytes32 operationId = timelock.hashOperationBatch(targets, values, calldatas, 0, salt);

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                operationId,
                bytes32(uint256(1 << uint8(TimelockController.OperationState.Ready)))
            )
        );
        governor.execute(targets, values, calldatas, keccak256(bytes(DESCRIPTION)));

        // One second past the delay it goes through.
        vm.warp(block.timestamp + MIN_DELAY + 1);
        _execute(10 ether);
        assertEq(recipient.balance, 10 ether);
    }

    // ------------------------------------------ flash-loan-governance defense

    function test_tokensAcquiredAfterTheSnapshotCarryNoWeight() public {
        uint256 proposalId = _propose(10 ether);
        _rollToActive(proposalId); // now past the snapshot block

        // The "flash loan": after the snapshot an attacker conjures 10x the
        // entire pre-existing supply and self-delegates.
        address attacker = makeAddr("attacker");
        _mintAndDelegate(attacker, 10_000 ether);
        vm.roll(block.number + 1);
        assertEq(token.getVotes(attacker), 10_000 ether); // live power: huge

        // …but the proposal reads power at its snapshot, where he had none.
        assertEq(governor.getVotes(attacker, governor.proposalSnapshot(proposalId)), 0);

        vm.prank(attacker);
        governor.castVote(proposalId, VOTE_FOR);

        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 0);
        _rollPastDeadline(proposalId);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ------------------------------------------------------- treasury custody

    function test_onlyTheTimelockCanMoveTreasuryFunds() public {
        assertEq(treasury.owner(), address(timelock));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        treasury.release(payable(recipient), 1 ether);

        // Not even the Governor may touch it directly — it must go through
        // a queued timelock operation.
        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(governor)));
        treasury.release(payable(recipient), 1 ether);

        vm.prank(address(timelock));
        treasury.release(payable(recipient), 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function test_releaseRejectsZeroRecipient() public {
        // Even a fully passed proposal cannot burn funds to address(0): ETH
        // sent there by a plain call succeeds and is gone forever.
        vm.prank(address(timelock));
        vm.expectRevert(Treasury.InvalidRecipient.selector);
        treasury.release(payable(address(0)), 1 ether);
    }
}
