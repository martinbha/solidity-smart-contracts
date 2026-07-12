// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {FlashLender} from "./FlashLender.sol";

/// @title GoodBorrower
/// @notice A well-behaved ERC-3156 borrower: it kicks off a flash loan, does
///         nothing risky with the borrowed funds, and repays principal + fee
///         from its own reserve inside the callback. It exists to show the
///         happy path — the loan the lender wants to see.
///
/// @dev The contract must already hold enough tokens to cover the fee: a
///      flash loan hands you the principal, never the fee. `onFlashLoan`
///      approves `amount + fee` back to the lender and returns the magic
///      value that proves to the lender the callback ran and consented.
contract GoodBorrower is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    error UntrustedLender(address caller);
    error UntrustedInitiator(address initiator);

    FlashLender public immutable lender;
    IERC20 public immutable token;

    constructor(FlashLender lender_) {
        lender = lender_;
        token = lender_.token();
    }

    /// @notice Start a flash loan for `amount`; the real work happens in the
    ///         callback the lender fires back into `onFlashLoan`.
    function borrow(uint256 amount, bytes calldata data) external {
        lender.flashLoan(this, address(token), amount, data);
    }

    /// @inheritdoc IERC3156FlashBorrower
    /// @dev Guards match the ERC-3156 security notes: only the trusted lender
    ///      may invoke the callback, and only a loan this contract itself
    ///      initiated is honored — otherwise anyone could name this contract
    ///      as receiver and make it pay fees for their loan.
    function onFlashLoan(address initiator, address token_, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        if (msg.sender != address(lender)) revert UntrustedLender(msg.sender);
        if (initiator != address(this)) revert UntrustedInitiator(initiator);

        // A real borrower would deploy `amount` into arbitrage, liquidation,
        // collateral swaps, etc. here. This one simply holds it and repays.

        IERC20(token_).forceApprove(address(lender), amount + fee);
        return CALLBACK_SUCCESS;
    }
}
