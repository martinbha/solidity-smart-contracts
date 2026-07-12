// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

/// @title FlashLender
/// @notice A minimal ERC-3156 flash lender over a single pooled ERC20. Anyone
///         may borrow any amount up to the pool balance with no collateral,
///         because the loan lives and dies inside one transaction: the lender
///         hands out the tokens, calls the borrower back, and then demands
///         principal + fee be returned before it returns. If the borrower
///         hasn't repaid by the end of the callback, the whole transaction
///         reverts and it is as if the loan never happened. Atomicity is the
///         collateral.
///
/// @dev The fee is a flat basis-point cut that always rounds UP, so the pool
///      never loses a wei to rounding — a borrower always repays at least as
///      much as the exact-rate fee.
///
///      Liquidity model, deliberately simple: the pool is permissionless and
///      this contract holds the tokens without issuing LP shares. There is no
///      withdraw path — `fund` is a ONE-WAY deposit; tokens sent in stay in
///      forever, and fees accrue to the anonymous pool. A real lender would
///      mint LP shares and let funders redeem principal + their fee share; the
///      teaching focus here is the loan mechanics, not the LP accounting, so
///      do not `fund` this expecting your capital back.
///
///      Token assumptions: the pool asset must be a standard, balance-stable
///      ERC20. A fee-on-transfer token would arrive short of `amount` at the
///      borrower yet be owed `amount + fee` back, so every loan of such a
///      token simply reverts — safe for the pool (atomicity protects it) but
///      unsupported.
///
///      Reentrancy policy: `flashLoan` is `nonReentrant`. A borrower that
///      tries to open a second flash loan from inside its `onFlashLoan`
///      callback reverts. This is stricter than ERC-3156 requires and than
///      production lenders do — Aave and Balancer permit safe nested loans by
///      re-checking balances after the callback — but forbidding nesting is
///      the simplest correct policy to reason about, and the one this lender
///      documents and tests.
contract FlashLender is IERC3156FlashLender, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Per ERC-3156, `onFlashLoan` must return this exact value so the
    ///      lender knows the callback ran and consented to the terms.
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice The single ERC20 this lender pools and lends.
    IERC20 public immutable token;

    /// @notice Flat fee in basis points charged on the borrowed amount.
    uint256 public immutable feeBps;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    error UnsupportedToken(address token);
    error AmountExceedsMaxLoan(uint256 amount, uint256 max);
    error CallbackFailed(bytes32 returned);
    error RepaymentNotApproved(uint256 needed, uint256 allowance);
    error FeeTooHigh(uint256 feeBps);

    event FlashLoan(address indexed borrower, uint256 amount, uint256 fee);
    event PoolFunded(address indexed from, uint256 amount);

    constructor(IERC20 token_, uint256 feeBps_) {
        // A fee at or above 100% is nonsensical (no borrower could ever repay)
        // and would only ever brick the lender; reject it at construction.
        if (feeBps_ >= BPS_DENOMINATOR) revert FeeTooHigh(feeBps_);
        token = token_;
        feeBps = feeBps_;
    }

    /// @notice Add liquidity to the lending pool. Purely a convenience over a
    ///         raw transfer so funding is a legible, event-emitting action.
    function fund(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit PoolFunded(msg.sender, amount);
    }

    /// @notice The most that can be borrowed right now: the entire pool.
    function maxFlashLoan(address token_) external view returns (uint256) {
        return token_ == address(token) ? token.balanceOf(address(this)) : 0;
    }

    /// @notice The fee charged on a loan of `amount`, rounded up so the pool
    ///         never loses to integer division.
    function flashFee(address token_, uint256 amount) external view returns (uint256) {
        if (token_ != address(token)) revert UnsupportedToken(token_);
        return _flashFee(amount);
    }

    /// @notice Borrow `amount`, receive the `onFlashLoan` callback, and repay
    ///         principal + fee before this function returns.
    /// @dev Flow: record the pre-loan balance, send the principal, call the
    ///      borrower, require it returned the magic value and approved the
    ///      repayment, then pull principal + fee back with `transferFrom`. The
    ///      final balance assertion is implicit: `safeTransferFrom` of
    ///      `amount + fee` can only succeed if the borrower actually holds and
    ///      approved that much, so the pool provably ends up with its
    ///      principal plus the fee.
    function flashLoan(IERC3156FlashBorrower receiver, address token_, uint256 amount, bytes calldata data)
        external
        nonReentrant
        returns (bool)
    {
        if (token_ != address(token)) revert UnsupportedToken(token_);
        uint256 max = token.balanceOf(address(this));
        if (amount > max) revert AmountExceedsMaxLoan(amount, max);

        uint256 fee = _flashFee(amount);

        token.safeTransfer(address(receiver), amount);

        bytes32 result = receiver.onFlashLoan(msg.sender, address(token), amount, fee, data);
        if (result != CALLBACK_SUCCESS) revert CallbackFailed(result);

        // Surface a clear error before attempting the pull: a borrower that
        // under-approved gets RepaymentNotApproved rather than an opaque
        // SafeERC20 failure.
        uint256 repayment = amount + fee;
        uint256 allowance = token.allowance(address(receiver), address(this));
        if (allowance < repayment) revert RepaymentNotApproved(repayment, allowance);

        token.safeTransferFrom(address(receiver), address(this), repayment);

        emit FlashLoan(address(receiver), amount, fee);
        return true;
    }

    function _flashFee(uint256 amount) internal view returns (uint256) {
        // Round up: (amount * bps + 9999) / 10000, so any non-zero fractional
        // fee costs the borrower a full extra wei and the pool never loses.
        return (amount * feeBps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
    }
}
