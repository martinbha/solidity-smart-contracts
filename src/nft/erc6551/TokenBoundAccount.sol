// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IERC6551Account {
    receive() external payable;

    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function state() external view returns (uint256);
    function isValidSigner(address signer, bytes calldata context) external view returns (bytes4 magicValue);
}

interface IERC6551Executable {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory result);
}

interface ISimpleTokenBoundExecutable {
    function execute(address to, uint256 value, bytes calldata data) external payable returns (bytes memory result);
}

/// @title TokenBoundAccount
/// @notice An account whose authority follows ownership of one ERC-721 token.
/// @dev Calls reach this implementation through an ERC-6551 proxy. The proxy
///      stores its immutable token tuple after the ERC-1167 runtime bytecode.
contract TokenBoundAccount is
    IERC6551Account,
    IERC6551Executable,
    ISimpleTokenBoundExecutable,
    IERC721Receiver,
    IERC165
{
    uint256 private immutable _deploymentChainId = block.chainid;

    uint256 public override state;

    error InvalidSigner(address caller);
    error OwnershipCycle();
    error UnsupportedOperation(uint8 operation);

    receive() external payable override {}

    /// @notice Returns the immutable token tuple embedded in the proxy code.
    function token() public view override returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        bytes memory footer = new bytes(0x60);
        assembly ("memory-safe") {
            // 0x2d bytes of proxy runtime + the 0x20-byte salt field.
            extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
        }
        return abi.decode(footer, (uint256, address, uint256));
    }

    /// @notice Resolves the account controller from live NFT ownership.
    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != _deploymentChainId) return address(0);
        return IERC721(tokenContract).ownerOf(tokenId);
    }

    function isValidSigner(address signer, bytes calldata) external view override returns (bytes4) {
        return signer == owner() ? IERC6551Account.isValidSigner.selector : bytes4(0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Executes a call using the compact surface requested by the
    ///         example, while retaining the standard operation-aware overload.
    function execute(address to, uint256 value, bytes calldata data)
        external
        payable
        override
        returns (bytes memory result)
    {
        return _execute(to, value, data);
    }

    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        override
        returns (bytes memory result)
    {
        if (operation != 0) revert UnsupportedOperation(operation);
        return _execute(to, value, data);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC6551Account).interfaceId
            || interfaceId == type(IERC6551Executable).interfaceId
            || interfaceId == type(ISimpleTokenBoundExecutable).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId;
    }

    function _execute(address to, uint256 value, bytes calldata data) private returns (bytes memory result) {
        if (msg.sender != owner()) revert InvalidSigner(msg.sender);

        state++;
        bool success;
        (success, result) = to.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }

        _rejectDirectOwnershipCycle();
    }

    /// @dev Reverts the complete call if it made this account the owner of
    ///      its controlling NFT. A burned controlling token is allowed.
    function _rejectDirectOwnershipCycle() private view {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != _deploymentChainId) return;

        try IERC721(tokenContract).ownerOf(tokenId) returns (address tokenOwner) {
            if (tokenOwner == address(this)) revert OwnershipCycle();
        } catch {}
    }
}
