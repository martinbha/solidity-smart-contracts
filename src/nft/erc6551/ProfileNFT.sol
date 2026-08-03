// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title ProfileNFT
/// @notice A deliberately small ERC-721 collection used to demonstrate
///         token-bound accounts. Anyone may mint a profile to any recipient.
contract ProfileNFT is ERC721 {
    uint256 public nextTokenId = 1;

    event ProfileMinted(address indexed owner, uint256 indexed tokenId);

    constructor() ERC721("Token-Bound Profile", "TBP") {}

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _safeMint(to, tokenId);
        emit ProfileMinted(to, tokenId);
    }
}
