// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
    using SafeERC20 for IERC20;

    bytes32 private constant DEBT_NAMESPACE = keccak256("solidity-smart-contracts.FlashAccountant.debt");

    address private transient _locker;
    uint256 private transient _unsettledDebtCount;

    error AlreadyLocked(address locker);
    error InvalidLocker(address locker);
    error NotLocker(address caller, address locker);
    error NoDebt(address locker, address token);
    error IncorrectTake(address token, uint256 expected, uint256 spent);
    error IncorrectSettlement(address token, uint256 expected, uint256 received);
    error UnsettledDebt(uint256 tokenCount);
    error ZeroAmount();

    event LockOpened(address indexed locker);
    event LockClosed(address indexed locker);
    event Taken(address indexed locker, address indexed token, uint256 amount, uint256 debt);
    event Settled(address indexed locker, address indexed token, uint256 amount);

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

    /// @notice Transfers tokens to the locker and records the amount owed in
    ///         a deterministic transient slot for `(locker, token)`.
    function take(address token, uint256 amount) external onlyLocker {
        if (amount == 0) revert ZeroAmount();

        bytes32 slot = _debtSlot(msg.sender, token);
        uint256 currentDebt = _tload(slot);
        uint256 updatedDebt = currentDebt + amount;

        if (currentDebt == 0) _unsettledDebtCount++;
        _tstore(slot, updatedDebt);

        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransfer(msg.sender, amount);
        uint256 balanceAfter = asset.balanceOf(address(this));
        uint256 spent = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
        if (spent != amount) revert IncorrectTake(token, amount, spent);

        emit Taken(msg.sender, token, amount, updatedDebt);
    }

    /// @notice Pulls the locker's entire debt for one token and clears its
    ///         transient slot. Fee-on-transfer repayment is rejected because
    ///         flash accounting must finish with exact asset conservation.
    function settle(address token) external onlyLocker {
        bytes32 slot = _debtSlot(msg.sender, token);
        uint256 amount = _tload(slot);
        if (amount == 0) revert NoDebt(msg.sender, token);

        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = asset.balanceOf(address(this));
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amount) revert IncorrectSettlement(token, amount, received);

        _tstore(slot, 0);
        _unsettledDebtCount--;
        emit Settled(msg.sender, token, amount);
    }

    function debt(address locker, address token) external view returns (uint256) {
        return _tload(_debtSlot(locker, token));
    }

    function _debtSlot(address locker, address token) private pure returns (bytes32) {
        return keccak256(abi.encode(DEBT_NAMESPACE, locker, token));
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
