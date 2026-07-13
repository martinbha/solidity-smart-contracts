// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title DaoGovernor
/// @notice The DAO's decision pipeline, assembled from OZ Governor modules.
///         Anyone may propose an on-chain action (targets/values/calldatas);
///         token holders vote For/Against/Abstain over a window; a passing
///         proposal is queued into the timelock and only executes after its
///         delay. Lifecycle: Pending → Active → Succeeded/Defeated →
///         Queued → Executed.
///
/// @dev How the modules divide the work:
///
///      - `GovernorVotes` reads voting power from the token's checkpoints at
///        the proposal snapshot (`propose` block + voting delay). Weight is
///        frozen there: tokens acquired later — flash-borrowed or bought —
///        count for nothing on that proposal.
///      - `GovernorVotesQuorumFraction(4)`: quorum is 4% of total supply,
///        also measured at the snapshot, so minting after the fact cannot
///        move the bar a live proposal has to clear.
///      - `GovernorCountingSimple` tallies For/Against/Abstain; quorum counts
///        For + Abstain votes.
///      - `GovernorSettings` makes delay/period/threshold governable: the
///        DAO can retune its own parameters through a proposal, no redeploy.
///      - `GovernorTimelockControl` routes execution through the timelock:
///        the Governor never holds power itself, it merely schedules. The
///        timelock delay is the users' exit window — time to leave before a
///        malicious-but-passed proposal can touch the treasury.
///
///      The demo parameters (1-block delay, 10-block period, 4% quorum) are
///      sized for local runs; production DAOs measure delay and period in
///      days. All three are adjustable by governance via `GovernorSettings`.
contract DaoGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    constructor(IVotes token, TimelockController timelock)
        Governor("DaoGovernor")
        GovernorSettings(
            1,
            /* voting delay: 1 block */
            10,
            /* voting period: 10 blocks */
            0 /* proposal threshold */
        )
        GovernorVotes(token)
        GovernorVotesQuorumFraction(
            4 /* quorum: 4% of supply */
        )
        GovernorTimelockControl(timelock)
    {}

    // The overrides below are required by Solidity to disambiguate between
    // the base Governor and the extension that actually implements each
    // piece; they all just defer to the module wired in above.

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function quorum(uint256 blockNumber) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
