// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title AuctionableNFT
/// @notice Minimal ERC721 with a public mint, used to have something to auction
///         in tests and local runs. Each mint hands the caller the next id.
contract AuctionableNFT is ERC721 {
    uint256 private _nextId;

    constructor() ERC721("Auctionable", "AUCT") {}

    function mint() external returns (uint256 tokenId) {
        tokenId = _nextId++;
        _mint(msg.sender, tokenId);
    }
}
