// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TransientReentrancyGuard
/// @notice A reentrancy guard whose lock lives in EIP-1153 transient storage.
/// @dev Transient state belongs to the contract for the whole transaction and
///      is discarded automatically when the transaction ends. The modifier
///      still clears the lock after a successful call so independent guarded
///      calls can execute sequentially in the same transaction.
abstract contract TransientReentrancyGuard {
    bool private transient _entered;

    error ReentrantCall();

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    function _reentrancyGuardEntered() internal view returns (bool) {
        return _entered;
    }
}

/// @title TransientVault
/// @notice Minimal ETH vault used to demonstrate the transient guard.
contract TransientVault is TransientReentrancyGuard {
    mapping(address account => uint256 amount) public balances;

    error InsufficientBalance(uint256 available, uint256 requested);
    error TransferFailed();

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    function deposit() external payable {
        balances[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @dev Deliberately performs the interaction before the balance update so
    ///      the guard, rather than checks-effects-interactions, is what blocks
    ///      the teaching contract's reentrancy attempt.
    function withdraw(uint256 amount) external nonReentrant {
        uint256 available = balances[msg.sender];
        if (amount > available) revert InsufficientBalance(available, amount);

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        balances[msg.sender] = available - amount;
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Minimal guarded entry point used for gas comparisons.
    function guardedNoop() external nonReentrant {}
}
