// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockYieldSource} from "./MockYieldSource.sol";

/// @title YieldVault
/// @notice ERC-4626 vault over a single ERC20 asset. Anyone deposits assets and
///         receives shares; `harvest()` pulls simulated interest from a
///         MockYieldSource into the vault, raising `totalAssets()` and thus the
///         value of every outstanding share.
///
/// @dev Inflation-attack defense: this vault relies on OZ v5's virtual-offset
///      mitigation (see `_decimalsOffset`). The classic attack: the first
///      depositor mints 1 wei of shares, then *donates* a large amount of
///      assets straight to the vault. Share price is now huge, so the next
///      depositor's assets round down to 0 shares (or lose most of their value
///      to rounding), which the attacker captures by redeeming their 1 share.
///
///      OZ counters by pricing conversions as if `10 ** offset` extra shares
///      and 1 extra asset always existed (virtual shares/assets that nobody
///      can redeem). A donation now inflates the price of the *virtual* shares
///      too, so the attacker's own donation is mostly captured by shares they
///      can never own — the attack costs more than it steals by a factor of
///      ~10^offset, making it economically irrational rather than merely hard.
contract YieldVault is ERC4626, Ownable {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_YIELD_RATE_BPS = 10_000; // 100% per day

    MockYieldSource public immutable yieldSource;

    /// @notice Daily interest rate in basis points of totalAssets, pro-rated
    ///         by the time elapsed since the last harvest.
    uint256 public yieldRateBps;

    /// @notice Timestamp of the last harvest; accrual starts from here.
    uint256 public lastHarvest;

    error YieldRateTooHigh(uint256 bps);

    event YieldRateUpdated(uint256 previousBps, uint256 newBps);
    event Harvested(address indexed caller, uint256 yieldRequested, uint256 yieldReceived);

    constructor(IERC20 asset_, MockYieldSource yieldSource_)
        ERC4626(asset_)
        ERC20("Yield Vault Share", "yVAST")
        Ownable(msg.sender)
    {
        yieldSource = yieldSource_;
        lastHarvest = block.timestamp;
    }

    /// @notice Pull the yield accrued since the last harvest from the source
    ///         into the vault. Permissionless: harvesting only ever raises the
    ///         share price, and because accrual is proportional to elapsed
    ///         time, calling it repeatedly pays no more than calling it once —
    ///         spamming cannot drain the source's reserve ahead of schedule.
    /// @dev The source caps payment at its reserve, so a drained source makes
    ///      harvest a no-op rather than a revert.
    function harvest() external returns (uint256 received) {
        uint256 elapsed = block.timestamp - lastHarvest;
        lastHarvest = block.timestamp;
        uint256 accrued = (totalAssets() * yieldRateBps * elapsed) / (BPS_DENOMINATOR * 1 days);
        received = yieldSource.payYield(accrued);
        emit Harvested(msg.sender, accrued, received);
    }

    /// @notice Set the simulated daily interest rate. Applies to the whole
    ///         period since the last harvest, so harvest first if the pending
    ///         accrual should keep the old rate.
    function setYieldRate(uint256 bps) external onlyOwner {
        if (bps > MAX_YIELD_RATE_BPS) revert YieldRateTooHigh(bps);
        emit YieldRateUpdated(yieldRateBps, bps);
        yieldRateBps = bps;
    }

    /// @dev Virtual offset of 6: conversions behave as if 10^6 virtual shares
    ///      back 1 virtual asset. Two effects, both proportional to 10^offset:
    ///      the victim's worst-case rounding loss is one share, worth at most
    ///      donation / (2 * 10^6); and roughly half the attacker's donation is
    ///      captured by the virtual shares nobody can redeem, so the attack
    ///      destroys ~10^6 times more attacker value than it can extract. Share
    ///      decimals become asset decimals + 6 (24 here) — cosmetic only.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
