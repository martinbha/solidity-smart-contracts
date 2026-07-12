// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title PiggyBank
/// @notice Time-locked ETH vault, designed to live behind ERC-1167 clones:
///         anyone can deposit, only the owner can withdraw, and only after
///         the unlock time. One canonical implementation is deployed once;
///         the factory then stamps out 45-byte clones that delegatecall here,
///         each with its own storage (own owner, own unlock, own balance).
///
/// @dev Clones cannot run constructors — a constructor would write the
///      *implementation's* storage, not the clone's — so all per-instance
///      setup lives in `initialize`, guarded by OZ's `initializer` so it can
///      run exactly once per clone. The implementation itself calls
///      `_disableInitializers()` in its constructor, so nobody can
///      initialize (and thereby own) the canonical copy. Same discipline as
///      the upgradeable Billboards; the difference is that a clone's
///      implementation address is baked into its bytecode forever, so unlike
///      the beacon fleet there is no upgrade lever to pull.
contract PiggyBank is Initializable, OwnableUpgradeable {
    /// @notice Timestamp after which the owner may withdraw.
    uint256 public unlockTime;

    error StillLocked(uint256 unlockTime, uint256 nowTimestamp);
    error WithdrawFailed();

    event BankInitialized(address indexed owner, uint256 unlockTime);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Runs once per clone, in that clone's own storage. An
    ///         `unlockTime_` in the past is allowed and simply makes the
    ///         bank withdrawable immediately — the lock is a commitment
    ///         device chosen by the creator, not a protocol invariant.
    function initialize(address initialOwner, uint256 unlockTime_) external initializer {
        __Ownable_init(initialOwner);
        unlockTime = unlockTime_;
        emit BankInitialized(initialOwner, unlockTime_);
    }

    /// @notice Anyone may feed the piggy bank.
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Send the full balance to the owner. Only the owner, only
    ///         after the unlock time.
    function withdraw() external onlyOwner {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < unlockTime) revert StillLocked(unlockTime, block.timestamp);

        address recipient = owner();
        uint256 amount = address(this).balance;
        emit Withdrawn(recipient, amount);
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }
}
