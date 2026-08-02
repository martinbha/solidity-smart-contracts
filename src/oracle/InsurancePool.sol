// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OptimisticOracle} from "./OptimisticOracle.sol";

/// @title InsurancePool
/// @notice Minimal oracle consumer that pays a named policyholder once a
///         claim has resolved true. Policy creation is owner-controlled so a
///         caller cannot front-run another policyholder's payout.
contract InsurancePool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Policy {
        address beneficiary;
        uint256 payout;
        bool claimed;
    }

    OptimisticOracle public immutable oracle;
    IERC20 public immutable payoutToken;
    address public immutable owner;

    mapping(bytes32 claimId => Policy policy) private _policies;

    event PolicyCreated(bytes32 indexed claimId, address indexed beneficiary, uint256 payout);
    event InsurancePaid(bytes32 indexed claimId, address indexed beneficiary, uint256 payout);

    error InvalidConfiguration();
    error NotOwner(address caller);
    error PolicyAlreadyExists(bytes32 claimId);
    error PolicyNotFound(bytes32 claimId);
    error NotBeneficiary(address caller, address beneficiary);
    error PolicyAlreadyClaimed(bytes32 claimId);
    error OracleResultUnresolved(bytes32 claimId);
    error ClaimNotPayable(bytes32 claimId);
    error IncorrectPayout(uint256 expected, uint256 spent);

    constructor(OptimisticOracle oracle_, IERC20 payoutToken_) {
        if (address(oracle_) == address(0) || address(payoutToken_) == address(0)) revert InvalidConfiguration();
        oracle = oracle_;
        payoutToken = payoutToken_;
        owner = msg.sender;
    }

    function createPolicy(bytes32 claimId, address beneficiary, uint256 payout) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        if (beneficiary == address(0) || payout == 0) revert InvalidConfiguration();
        if (_policies[claimId].beneficiary != address(0)) revert PolicyAlreadyExists(claimId);

        _policies[claimId] = Policy({beneficiary: beneficiary, payout: payout, claimed: false});
        emit PolicyCreated(claimId, beneficiary, payout);
    }

    function claim(bytes32 claimId) external nonReentrant {
        Policy storage policy = _policies[claimId];
        if (policy.beneficiary == address(0)) revert PolicyNotFound(claimId);
        if (msg.sender != policy.beneficiary) revert NotBeneficiary(msg.sender, policy.beneficiary);
        if (policy.claimed) revert PolicyAlreadyClaimed(claimId);

        (bool resolved, bool value) = oracle.getResult(claimId);
        if (!resolved) revert OracleResultUnresolved(claimId);
        if (!value) revert ClaimNotPayable(claimId);

        policy.claimed = true;
        uint256 balanceBefore = payoutToken.balanceOf(address(this));
        payoutToken.safeTransfer(msg.sender, policy.payout);
        uint256 balanceAfter = payoutToken.balanceOf(address(this));
        uint256 spent = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
        if (spent != policy.payout) revert IncorrectPayout(policy.payout, spent);

        emit InsurancePaid(claimId, msg.sender, policy.payout);
    }

    function getPolicy(bytes32 claimId) external view returns (Policy memory) {
        return _policies[claimId];
    }
}
