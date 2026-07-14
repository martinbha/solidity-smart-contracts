// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Treasury
/// @notice The thing being governed: a pot of ETH that only its owner can
///         release. The owner is the *TimelockController*, not the Governor
///         and not any person — so the only path to the money is a proposal
///         that passed a vote and then sat out the timelock delay in public
///         view.
///
/// @dev Why the timelock owns it instead of the Governor: if the Governor
///      were the owner, a passed proposal could execute in the same block it
///      succeeded — a hostile majority (or a bug in the Governor) would move
///      funds instantly. Parking ownership in the timelock makes every
///      outcome, even a legitimate one, wait out `minDelay` where everyone
///      can see it queued and act (exit positions, cancel via the canceller
///      role) before it lands.
contract Treasury is Ownable {
    event Funded(address indexed from, uint256 amount);
    event Released(address indexed to, uint256 amount);

    error InvalidRecipient();
    error TransferFailed();

    constructor(address timelock) Ownable(timelock) {}

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Sends `amount` wei to `to`. Only the owner — the timelock —
    ///         may call, and the timelock only calls what governance queued.
    /// @dev Rejects a zero recipient: a plain `call` to `address(0)` succeeds
    ///      and burns the ETH, so a proposal with an unset recipient would
    ///      sail through vote, timelock, and execution and quietly torch the
    ///      funds. Same guard as the multisig's zero-target check.
    function release(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Released(to, amount);
    }
}
