// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Callback implemented by a contract that opens a flash-accounting
///         session. The accountant calls it while the transient lock is open.
interface IFlashAccountantCallback {
    function lockAcquired(bytes calldata actions) external;
}

/// @title FlashAccountant
/// @notice Runs an atomic callback session whose token debts must be zero when
///         control returns to `lock`.
/// @dev The current locker and outstanding-token count use Solidity's
///      `transient` storage location. Per-token debts are added separately via
///      derived transient slots because Solidity does not support transient
///      mappings.
contract FlashAccountant {
    address private transient _locker;
    uint256 private transient _unsettledDebtCount;

    error AlreadyLocked(address locker);
    error InvalidLocker(address locker);
    error NotLocker(address caller, address locker);
    error UnsettledDebt(uint256 tokenCount);

    event LockOpened(address indexed locker);
    event LockClosed(address indexed locker);

    modifier onlyLocker() {
        address locker = _locker;
        if (msg.sender != locker) revert NotLocker(msg.sender, locker);
        _;
    }

    /// @notice Opens one callback session. Nested sessions are rejected, and
    ///         any outstanding token debt reverts the entire transaction.
    function lock(bytes calldata actions) external {
        address locker = _locker;
        if (locker != address(0)) revert AlreadyLocked(locker);
        if (msg.sender.code.length == 0) revert InvalidLocker(msg.sender);

        _locker = msg.sender;
        emit LockOpened(msg.sender);

        IFlashAccountantCallback(msg.sender).lockAcquired(actions);

        uint256 tokenCount = _unsettledDebtCount;
        if (tokenCount != 0) revert UnsettledDebt(tokenCount);

        _locker = address(0);
        emit LockClosed(msg.sender);
    }

    function currentLocker() external view returns (address) {
        return _locker;
    }

    function outstandingDebtCount() external view returns (uint256) {
        return _unsettledDebtCount;
    }
}
