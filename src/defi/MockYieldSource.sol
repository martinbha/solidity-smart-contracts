// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockYieldSource
/// @notice Stands in for an external protocol that pays interest. It holds a
///         reserve of the underlying asset (funded by anyone) and pays yield
///         to the vault on demand, capped at whatever it actually holds — so
///         "yield" can never be conjured beyond what was explicitly funded.
contract MockYieldSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    /// @notice The only address allowed to pull yield. Set once.
    address public vault;

    error VaultAlreadySet();
    error NotVault();
    error ZeroAddress();

    event Funded(address indexed from, uint256 amount);
    event YieldPaid(uint256 requested, uint256 paid);

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    /// @notice One-time binding to the vault, done post-deploy because the
    ///         vault needs this contract's address at construction.
    function setVault(address vault_) external {
        if (vault != address(0)) revert VaultAlreadySet();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
    }

    /// @notice Deposit assets into the reserve that future yield is paid from.
    function fund(uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice Pay up to `amount` of yield to the vault, capped at the reserve.
    /// @return paid The amount actually transferred.
    function payYield(uint256 amount) external returns (uint256 paid) {
        if (msg.sender != vault) revert NotVault();
        uint256 reserve = asset.balanceOf(address(this));
        paid = amount > reserve ? reserve : amount;
        if (paid > 0) asset.safeTransfer(vault, paid);
        emit YieldPaid(amount, paid);
    }
}
