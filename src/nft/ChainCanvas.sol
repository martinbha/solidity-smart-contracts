// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SVGRenderer} from "./SVGRenderer.sol";

/// @title ChainCanvas
/// @notice Fully on-chain generative art ERC721. The contract stores only a
///         32-byte seed per token; `tokenURI` builds the metadata JSON and
///         the SVG image in Solidity on every call and returns them as
///         nested base64 data URIs. No IPFS, no servers: the art exists
///         exactly as long as the chain does, and it slowly changes as the
///         token ages in blocks.
///
/// @dev Randomness honesty: the seed is `keccak256(tokenId, minter,
///      block.prevrandao)`. The block proposer can bias prevrandao (one bit
///      per slot by withholding a block), the minter can dry-run the mint
///      and wait for a seed they like, and a minting *contract* can grind
///      harder: mint, inspect `traitsOf` in the same transaction, and revert
///      unless the rare trait landed — paying only gas per attempt, ~50
///      tries buys near-certain Aurora. That is perfectly fine for which of
///      five palettes a picture gets (Nouns accepts the same property), and
///      categorically NOT fine for anything worth money — lotteries, loot
///      drops with market value, gambling — which need commit-reveal (see
///      games/RockPaperScissors) or an oracle like VRF.
///
///      Immutability trade-off: the renderer is an internal library compiled
///      into this contract, so the art — bugs included — is frozen at deploy
///      time. That is the point of "art forever", but it cuts both ways: a
///      rendering bug can never be patched. Production systems that want
///      fixable art (Nouns) route tokenURI through a swappable descriptor
///      contract instead, trading permanence for upgradability.
///
///      Gas reality: minting stores one seed and one block number; the
///      expensive string building in tokenURI runs only in view calls,
///      which cost nothing off-chain.
contract ChainCanvas is ERC721, Ownable {
    using Strings for uint256;

    uint256 public constant MINT_PRICE = 0.001 ether;

    struct TokenData {
        uint256 seed;
        uint64 mintBlock;
    }

    mapping(uint256 => TokenData) private _tokenData;

    /// @notice Id assigned to the next mint. Ids start at 1.
    uint256 public nextTokenId = 1;

    error WrongMintPrice(uint256 sent, uint256 required);
    error WithdrawFailed();

    event Minted(uint256 indexed tokenId, address indexed minter, uint256 seed);

    constructor() ERC721("Chain Canvas", "CANVAS") Ownable(msg.sender) {}

    /// @notice Mint one canvas for exactly MINT_PRICE. Only the seed and the
    ///         mint block are stored, so gas is near-constant regardless of
    ///         how intricate the rendered art is.
    /// @dev Supply is deliberately unbounded: this collection derives value
    ///      from the pattern it teaches, not scarcity. A collection whose
    ///      economics depend on rarity needs a hard cap checked here.
    function mint() external payable returns (uint256 tokenId) {
        if (msg.value != MINT_PRICE) revert WrongMintPrice(msg.value, MINT_PRICE);

        tokenId = nextTokenId++;
        uint256 seed = uint256(keccak256(abi.encodePacked(tokenId, msg.sender, block.prevrandao)));
        // Cast cannot truncate: block numbers fit uint64 for the next ~10^13 years.
        // forge-lint: disable-next-line(unsafe-typecast)
        _tokenData[tokenId] = TokenData({seed: seed, mintBlock: uint64(block.number)});

        emit Minted(tokenId, msg.sender, seed);
        _mint(msg.sender, tokenId);
    }

    /// @notice Full metadata as a `data:application/json;base64,...` URI whose
    ///         `image` field is itself a `data:image/svg+xml;base64,...` URI.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(tokenJSON(tokenId)))));
    }

    /// @notice The metadata JSON before base64 encoding. Public so tests and
    ///         integrators can parse the envelope without a decoder.
    function tokenJSON(uint256 tokenId) public view returns (string memory) {
        _requireOwned(tokenId);
        TokenData storage data = _tokenData[tokenId];
        SVGRenderer.Traits memory t = SVGRenderer.traitsFromSeed(data.seed);
        uint256 age = block.number - data.mintBlock;
        string memory svg = SVGRenderer.render(data.seed, age);

        // solhint-disable quotes
        string memory attributes = string(
            abi.encodePacked(
                '[{"trait_type":"Palette","value":"',
                SVGRenderer.paletteName(t.palette),
                '"},{"trait_type":"Shape","value":"',
                SVGRenderer.shapeName(t.shape),
                '"},{"trait_type":"Stroke","value":"',
                SVGRenderer.strokeName(t.stroke),
                '"},{"trait_type":"Aurora","value":"',
                t.aurora ? "Yes" : "No",
                '"},{"display_type":"number","trait_type":"Age (blocks)","value":',
                age.toString(),
                "}]"
            )
        );
        return string(
            abi.encodePacked(
                '{"name":"Chain Canvas #',
                tokenId.toString(),
                '","description":"Fully on-chain generative art: traits, SVG, and metadata are built by the contract on every call. The outer ring grows as the token ages in blocks.",',
                '"attributes":',
                attributes,
                ',"image":"data:image/svg+xml;base64,',
                Base64.encode(bytes(svg)),
                '"}'
            )
        );
    }

    /// @notice Decoded traits for a token, derived fresh from its seed.
    function traitsOf(uint256 tokenId) external view returns (SVGRenderer.Traits memory) {
        _requireOwned(tokenId);
        return SVGRenderer.traitsFromSeed(_tokenData[tokenId].seed);
    }

    /// @notice The stored seed for a token (the only per-token art state).
    function seedOf(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return _tokenData[tokenId].seed;
    }

    /// @notice Blocks elapsed since the token was minted; drives the age ring.
    function ageOf(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return block.number - _tokenData[tokenId].mintBlock;
    }

    /// @notice Send accumulated mint fees to the owner.
    function withdraw() external onlyOwner {
        (bool ok,) = payable(owner()).call{value: address(this).balance}("");
        if (!ok) revert WithdrawFailed();
    }
}
