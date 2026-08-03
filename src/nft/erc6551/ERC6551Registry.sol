// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title ERC6551Registry
/// @notice Permissionless registry for deterministic token-bound accounts.
/// @dev The deployed account is the ERC-6551 ERC-1167 proxy: a minimal proxy
///      followed by immutable `(salt, chainId, tokenContract, tokenId)` data.
contract ERC6551Registry {
    event ERC6551AccountCreated(
        address account,
        address indexed implementation,
        bytes32 salt,
        uint256 chainId,
        address indexed tokenContract,
        uint256 indexed tokenId
    );

    error AccountCreationFailed();

    /// @notice Creates the account unless it already exists, in which case
    ///         the same deterministic address is returned.
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address accountAddress) {
        bytes memory code = _creationCode(implementation, salt, chainId, tokenContract, tokenId);
        accountAddress = Create2.computeAddress(salt, keccak256(code), address(this));

        if (accountAddress.code.length != 0) return accountAddress;

        assembly ("memory-safe") {
            accountAddress := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (accountAddress == address(0)) revert AccountCreationFailed();

        emit ERC6551AccountCreated(accountAddress, implementation, salt, chainId, tokenContract, tokenId);
    }

    /// @notice Returns the counterfactual account address for a token tuple.
    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external
        view
        returns (address)
    {
        bytes memory code = _creationCode(implementation, salt, chainId, tokenContract, tokenId);
        return Create2.computeAddress(salt, keccak256(code), address(this));
    }

    function _creationCode(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) private pure returns (bytes memory) {
        return abi.encodePacked(
            // Constructor: copy the following 173 bytes into runtime code.
            hex"3d60ad80600a3d3981f3",
            // ERC-1167 runtime header, implementation, and footer.
            hex"363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3",
            // ERC-6551 immutable footer. abi.encode keeps every field 32 bytes.
            abi.encode(salt, chainId, tokenContract, tokenId)
        );
    }
}
