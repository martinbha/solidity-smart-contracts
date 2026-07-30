// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BatchDelegate
/// @notice Delegation target that lets an EIP-7702 account execute multiple
///         calls atomically from its own address.
/// @dev EIP-7702 runs this code in the delegating account's context:
///      `address(this)` is the account, its balance funds value-bearing calls,
///      and its storage persists across delegations. The self-call check means
///      a batch must be initiated by a transaction signed by that account;
///      arbitrary callers cannot use the delegated authority.
contract BatchDelegate {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    error OnlySelf();
    error CallFailed(uint256 index, bytes reason);

    event CallExecuted(uint256 indexed index, address indexed target, uint256 value);

    /// @notice Allows the delegated account to receive plain ETH transfers.
    receive() external payable {}

    /// @notice Executes every call in order and returns each call's raw result.
    /// @dev A failure reverts the entire batch, including earlier calls.
    function executeBatch(Call[] calldata calls) external payable returns (bytes[] memory results) {
        if (msg.sender != address(this)) revert OnlySelf();

        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            Call calldata call_ = calls[i];
            (bool success, bytes memory result) = call_.to.call{value: call_.value}(call_.data);
            if (!success) revert CallFailed(i, result);

            results[i] = result;
            emit CallExecuted(i, call_.to, call_.value);
        }
    }
}
