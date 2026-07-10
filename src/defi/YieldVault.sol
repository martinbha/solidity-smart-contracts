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
    uint256 public constant MAX_YIELD_RATE_BPS = 10_000; // 100% per harvest

    MockYieldSource public immutable yieldSource;

    /// @notice Interest accrued per harvest, in basis points of totalAssets.
    uint256 public yieldRateBps;

    error YieldRateTooHigh(uint256 bps);

    event YieldRateUpdated(uint256 previousBps, uint256 newBps);
    event Harvested(address indexed caller, uint256 yieldRequested, uint256 yieldReceived);

    constructor(IERC20 asset_, MockYieldSource yieldSource_)
        ERC4626(asset_)
        ERC20("Yield Vault Share", "yVAST")
        Ownable(msg.sender)
    {
        yieldSource = yieldSource_;
    }

    /// @notice Pull accrued yield from the source into the vault. Permissionless:
    ///         harvesting only ever raises the share price, so anyone may poke it.
    /// @dev The source caps payment at its reserve, so a drained source makes
    ///      harvest a no-op rather than a revert.
    function harvest() external returns (uint256 received) {
        uint256 accrued = (totalAssets() * yieldRateBps) / BPS_DENOMINATOR;
        received = yieldSource.payYield(accrued);
        emit Harvested(msg.sender, accrued, received);
    }

    /// @notice Set the simulated interest rate applied on each harvest.
    function setYieldRate(uint256 bps) external onlyOwner {
        if (bps > MAX_YIELD_RATE_BPS) revert YieldRateTooHigh(bps);
        emit YieldRateUpdated(yieldRateBps, bps);
        yieldRateBps = bps;
    }

    /// @dev Virtual offset of 3: conversions behave as if 1000 virtual shares
    ///      back 1 virtual asset. An attacker donating D assets to steal from a
    ///      victim depositing d loses ~D / 10^3 to the virtual shares while
    ///      capturing at most the victim's rounding loss — for any realistic D
    ///      the attack destroys ~1000x more attacker value than it extracts,
    ///      which is why OZ calls the offset a *deterrent*, not just a bound.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }
}
