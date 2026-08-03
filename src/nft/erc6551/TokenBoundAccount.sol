// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IERC6551Account {
    receive() external payable;

    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function state() external view returns (uint256);
    function isValidSigner(address signer, bytes calldata context) external view returns (bytes4 magicValue);
}

/// @title TokenBoundAccount
/// @notice An account whose authority follows ownership of one ERC-721 token.
/// @dev Calls reach this implementation through an ERC-6551 proxy. The proxy
///      stores its immutable token tuple after the ERC-1167 runtime bytecode.
contract TokenBoundAccount is IERC6551Account, IERC165 {
    uint256 private immutable _deploymentChainId = block.chainid;

    uint256 public override state;

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

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC6551Account).interfaceId;
    }
}
