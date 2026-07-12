// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NaiveBank
/// @notice VULNERABLE ON PURPOSE. A share-based vault that prices its shares
///         off its own *spot* token balance — exactly the mistake a flash
///         loan is built to punish. Do not deploy this; it exists so the
///         test and exploit script can drain it and make the lesson concrete.
///
/// @dev The bug: `sharePrice()` reads `token.balanceOf(this)` directly, so it
///      counts every token the contract holds — including any that arrived
///      WITHOUT minting shares. Real vaults accumulate such tokens all the
///      time: protocol fees, yield swept in, or a plain donation. Here those
///      unbacked tokens sit in the spot balance and inflate the price of the
///      shares that DO exist, and because shares can be minted at that same
///      spot price, the mispricing is round-trippable.
///
///      The concrete attack this enables (see the exploit script/test), which
///      needs ZERO attacker capital — that is the whole point of a flash
///      loan — against a bank holding an unbacked reserve R:
///        1. flash-borrow an amount F (any size; even F ~= R works)
///        2. deposit F: with the reserve's tokens already in the balance but
///           few/no shares behind them, the deposit mints shares whose fair
///           backing is worth more than F
///        3. redeem those shares immediately: the payout is F plus a
///           proportional slice of the unbacked reserve
///        4. repay F + fee; keep the skimmed reserve
///
///      Crucially the donation-then-redeem variant against an HONEST pool of
///      depositors does NOT profit: a donation is shared pro-rata, so you
///      just hand money to the other shareholders. The flash loan only wins
///      here because the reserve is UNBACKED — no shares stand between the
///      attacker and those tokens.
///
///      This is the self-contained version of the lesson. The more famous —
///      and more dangerous — shape is cross-protocol: protocol B reads this
///      kind of spot price as an ORACLE (e.g. to value collateral), and an
///      attacker flash-loans to move the price here, then borrows or
///      liquidates against the warped valuation over on B, all in one
///      transaction. Any contract that trusts a spot balance or spot AMM
///      reserve — its own or another's — is exposed.
///
///      The fix is to never price off a spot quantity. Two robust patterns:
///      (1) track backing in a storage accumulator that only moves on
///      deposit/redeem — a real ERC-4626 vault does this, and its
///      virtual-shares offset raises the per-share price floor so a donation
///      can't round a later depositor to zero (see src/defi/YieldVault.sol
///      for that offset explained in depth); (2) read value from a
///      manipulation-resistant oracle — a sufficiently long TWAP, or an
///      external feed like Chainlink — that a single transaction cannot move.
///      This contract does the wrong thing on purpose.
contract NaiveBank {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    error NothingDeposited();
    error NoShares();

    event Deposited(address indexed who, uint256 amount, uint256 sharesMinted);
    event Redeemed(address indexed who, uint256 sharesBurned, uint256 amountOut);

    constructor(IERC20 token_) {
        token = token_;
    }

    /// @notice Shares are worth `totalAssets / totalShares` — and totalAssets
    ///         is the naive spot balance. Returned scaled by 1e18. With no
    ///         shares yet, one share is worth one token (the seed price).
    function sharePrice() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (token.balanceOf(address(this)) * 1e18) / totalShares;
    }

    /// @notice Deposit `amount` tokens and mint shares at the current (spot,
    ///         manipulable) price.
    function deposit(uint256 amount) external returns (uint256 minted) {
        if (amount == 0) revert NothingDeposited();
        // Mint against the price BEFORE this deposit lands, so the depositor
        // is not diluted by their own tokens.
        uint256 price = sharePrice();
        minted = (amount * 1e18) / price;
        shares[msg.sender] += minted;
        totalShares += minted;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, minted);
    }

    /// @notice Burn all of the caller's shares and pay out their spot value.
    function redeem() external returns (uint256 amountOut) {
        uint256 held = shares[msg.sender];
        if (held == 0) revert NoShares();
        amountOut = (held * sharePrice()) / 1e18;
        shares[msg.sender] = 0;
        totalShares -= held;
        token.safeTransfer(msg.sender, amountOut);
        emit Redeemed(msg.sender, held, amountOut);
    }
}
