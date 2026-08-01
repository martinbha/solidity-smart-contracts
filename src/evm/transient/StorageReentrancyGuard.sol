// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title StorageReentrancyGuard
/// @notice Classic persistent-storage guard used as the EIP-1153 baseline.
abstract contract StorageReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status = NOT_ENTERED;

    error ReentrantCall();

    modifier nonReentrant() {
        if (_status == ENTERED) revert ReentrantCall();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

/// @title StorageVault
/// @notice Behaviorally equivalent vault for comparing persistent guard gas.
contract StorageVault is StorageReentrancyGuard {
    mapping(address account => uint256 amount) public balances;

    error InsufficientBalance(uint256 available, uint256 requested);
    error TransferFailed();

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    function deposit() external payable {
        balances[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external nonReentrant {
        uint256 available = balances[msg.sender];
        if (amount > available) revert InsufficientBalance(available, amount);

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        balances[msg.sender] = available - amount;
        emit Withdrawn(msg.sender, amount);
    }

    function guardedNoop() external nonReentrant {}
}
