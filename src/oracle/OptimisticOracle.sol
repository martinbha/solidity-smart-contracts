// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title OptimisticOracle
/// @notice Accepts bonded truth assertions that become final after an
///         undisputed challenge window or a resolver decision.
contract OptimisticOracle is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Assertion {
        address asserter;
        uint40 deadline;
        bool assertedValue;
        bool disputed;
        bool resolved;
        bool result;
        address disputer;
    }

    IERC20 public immutable bondToken;
    address public immutable resolver;
    uint256 public immutable bondAmount;
    uint40 public immutable challengeWindow;

    mapping(bytes32 claimId => Assertion assertion) private _assertions;
    mapping(address account => uint256 amount) public withdrawableBonds;

    uint256 public totalEscrowedBonds;
    uint256 public totalWithdrawableBonds;

    event TruthAsserted(bytes32 indexed claimId, address indexed asserter, bool value, uint40 deadline);
    event AssertionDisputed(bytes32 indexed claimId, address indexed disputer);
    event AssertionSettled(bytes32 indexed claimId, bool value, address indexed recipient, uint256 reward);
    event AssertionResolved(bytes32 indexed claimId, bool value, address indexed winner, uint256 reward);
    event BondWithdrawn(address indexed account, uint256 amount);

    error InvalidConfiguration();
    error AssertionAlreadyExists(bytes32 claimId);
    error AssertionNotFound(bytes32 claimId);
    error AssertionAlreadyResolved(bytes32 claimId);
    error DisputedAssertionCannotSettle(bytes32 claimId);
    error AssertionAlreadyDisputed(bytes32 claimId);
    error AssertionNotDisputed(bytes32 claimId);
    error CannotDisputeOwnAssertion();
    error ChallengeWindowOpen(uint40 deadline);
    error ChallengeWindowClosed(uint40 deadline);
    error NotResolver(address caller);
    error IncorrectBondTransfer(uint256 expected, uint256 received);
    error IncorrectBondPayout(uint256 expected, uint256 spent, uint256 received);
    error NoBondToWithdraw();

    constructor(IERC20 bondToken_, address resolver_, uint256 bondAmount_, uint40 challengeWindow_) {
        if (address(bondToken_) == address(0) || resolver_ == address(0) || bondAmount_ == 0 || challengeWindow_ == 0) {
            revert InvalidConfiguration();
        }

        bondToken = bondToken_;
        resolver = resolver_;
        bondAmount = bondAmount_;
        challengeWindow = challengeWindow_;
    }

    /// @notice Post the fixed bond and open a claim for challenges.
    function assertTruth(bytes32 claimId, bool value) external nonReentrant {
        if (_assertions[claimId].asserter != address(0)) revert AssertionAlreadyExists(claimId);

        _collectBond(msg.sender);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 deadline = uint40(block.timestamp + challengeWindow);
        _assertions[claimId] = Assertion({
            asserter: msg.sender,
            deadline: deadline,
            assertedValue: value,
            disputed: false,
            resolved: false,
            result: false,
            disputer: address(0)
        });
        totalEscrowedBonds += bondAmount;

        emit TruthAsserted(claimId, msg.sender, value, deadline);
    }

    /// @notice Challenge an assertion before its deadline by posting the same
    ///         fixed bond. A disputed claim must be decided by the resolver.
    function disputeAssertion(bytes32 claimId) external nonReentrant {
        Assertion storage assertion = _assertions[claimId];
        if (assertion.asserter == address(0)) revert AssertionNotFound(claimId);
        if (assertion.resolved) revert AssertionAlreadyResolved(claimId);
        if (assertion.disputed) revert AssertionAlreadyDisputed(claimId);
        if (msg.sender == assertion.asserter) revert CannotDisputeOwnAssertion();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > assertion.deadline) revert ChallengeWindowClosed(assertion.deadline);

        _collectBond(msg.sender);
        assertion.disputed = true;
        assertion.disputer = msg.sender;
        totalEscrowedBonds += bondAmount;

        emit AssertionDisputed(claimId, msg.sender);
    }

    /// @notice Finalize an undisputed assertion after its challenge window.
    ///         The asserter's bond becomes available through pull payment.
    function settle(bytes32 claimId) external {
        Assertion storage assertion = _assertions[claimId];
        if (assertion.asserter == address(0)) revert AssertionNotFound(claimId);
        if (assertion.resolved) revert AssertionAlreadyResolved(claimId);
        if (assertion.disputed) revert DisputedAssertionCannotSettle(claimId);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= assertion.deadline) revert ChallengeWindowOpen(assertion.deadline);

        assertion.resolved = true;
        assertion.result = assertion.assertedValue;
        totalEscrowedBonds -= bondAmount;
        _credit(assertion.asserter, bondAmount);

        emit AssertionSettled(claimId, assertion.result, assertion.asserter, bondAmount);
    }

    /// @notice Decide a disputed claim. The party whose position matches the
    ///         resolved truth receives both bonds through the pull ledger.
    function resolve(bytes32 claimId, bool truth) external {
        if (msg.sender != resolver) revert NotResolver(msg.sender);

        Assertion storage assertion = _assertions[claimId];
        if (assertion.asserter == address(0)) revert AssertionNotFound(claimId);
        if (assertion.resolved) revert AssertionAlreadyResolved(claimId);
        if (!assertion.disputed) revert AssertionNotDisputed(claimId);

        assertion.resolved = true;
        assertion.result = truth;
        address winner = truth == assertion.assertedValue ? assertion.asserter : assertion.disputer;
        uint256 reward = bondAmount * 2;
        totalEscrowedBonds -= reward;
        _credit(winner, reward);

        emit AssertionResolved(claimId, truth, winner, reward);
    }

    /// @notice Pull all assertion rewards credited to the caller.
    function withdrawBond() external nonReentrant {
        uint256 amount = withdrawableBonds[msg.sender];
        if (amount == 0) revert NoBondToWithdraw();

        withdrawableBonds[msg.sender] = 0;
        totalWithdrawableBonds -= amount;

        uint256 balanceBefore = bondToken.balanceOf(address(this));
        uint256 recipientBalanceBefore = bondToken.balanceOf(msg.sender);
        bondToken.safeTransfer(msg.sender, amount);
        uint256 balanceAfter = bondToken.balanceOf(address(this));
        uint256 recipientBalanceAfter = bondToken.balanceOf(msg.sender);
        uint256 spent = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
        uint256 received =
            recipientBalanceAfter >= recipientBalanceBefore ? recipientBalanceAfter - recipientBalanceBefore : 0;
        if (spent != amount || received != amount) revert IncorrectBondPayout(amount, spent, received);

        emit BondWithdrawn(msg.sender, amount);
    }

    /// @notice Bonds physically held should always equal escrow plus credits.
    function accountedBondBalance() external view returns (uint256) {
        return totalEscrowedBonds + totalWithdrawableBonds;
    }

    function getResult(bytes32 claimId) external view returns (bool resolved, bool value) {
        Assertion storage assertion = _assertions[claimId];
        return (assertion.resolved, assertion.result);
    }

    function getAssertion(bytes32 claimId) external view returns (Assertion memory) {
        return _assertions[claimId];
    }

    function _collectBond(address from) private {
        uint256 balanceBefore = bondToken.balanceOf(address(this));
        bondToken.safeTransferFrom(from, address(this), bondAmount);
        uint256 balanceAfter = bondToken.balanceOf(address(this));
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != bondAmount) revert IncorrectBondTransfer(bondAmount, received);
    }

    function _credit(address account, uint256 amount) private {
        withdrawableBonds[account] += amount;
        totalWithdrawableBonds += amount;
    }
}
