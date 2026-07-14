// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title GovToken
/// @notice ERC20 whose balances double as checkpointed voting power.
///         `ERC20Votes` writes a checkpoint on every balance-affecting
///         transfer, so the Governor can ask "how many votes did this address
///         hold at block N?" long after balances have moved on. Reading power
///         *at the proposal snapshot* instead of at vote time is the defense
///         against flash-loan governance: tokens borrowed after the snapshot
///         carry zero weight, no matter how many arrive.
///
/// @dev Two properties that surprise newcomers:
///
///      - Balances are NOT votes. Power only counts once delegated — even to
///        yourself (`delegate(msg.sender)`). Checkpointing every holder on
///        every transfer would make ERC20 transfers cost a checkpoint write
///        for passive holders who never vote; requiring an explicit opt-in
///        moves that cost to the addresses that actually participate.
///      - Checkpoints record history going *forward* from delegation: power
///        acquired or delegated after a snapshot is invisible to it.
///
///      `ERC20Permit` rides along so voters can be onboarded gaslessly (see
///      the signatures pattern) and because `ERC20Votes` builds on the same
///      EIP-712 domain for signature-based delegation (`delegateBySig`).
///
///      The public unrestricted mint keeps local demos frictionless — but
///      note what it gives away: anyone can mint themselves quorum *before*
///      a snapshot and pass any proposal. Checkpointing only defends against
///      power acquired *after* the snapshot; who may create supply, and on
///      what schedule, is exactly as security-critical as the timelock.
contract GovToken is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("Governance Token", "GOV") ERC20Permit("Governance Token") {}

    /// @notice Mint `amount` tokens to `to`. Unrestricted by design (test asset).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Solidity requires explicit tie-breaks where ERC20 and its extensions
    // both override the same hook.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
