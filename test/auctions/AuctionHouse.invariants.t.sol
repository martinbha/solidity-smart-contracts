// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AuctionHouse} from "../../src/auctions/AuctionHouse.sol";
import {AuctionableNFT} from "../../src/auctions/AuctionableNFT.sol";

/// @notice Drives the auction house with random actions from a set of actors,
///         tracking exactly what the contract owes so the invariant can check
///         its ETH balance never drifts from its obligations.
contract AuctionHandler is Test {
    AuctionHouse public house;
    AuctionableNFT public nft;

    address[] public actors;
    uint256[] public englishIds;
    uint256[] public dutchIds;

    constructor(AuctionHouse house_, AuctionableNFT nft_) {
        house = house_;
        nft = nft_;
        for (uint256 i = 0; i < 4; i++) {
            address actor = address(uint160(0xACC0 + i));
            actors.push(actor);
            vm.deal(actor, 1000 ether);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function createEnglish(uint256 seed, uint256 reserve) external {
        address seller = _actor(seed);
        reserve = bound(reserve, 0, 5 ether);
        vm.startPrank(seller);
        uint256 tokenId = nft.mint();
        nft.approve(address(house), tokenId);
        uint256 id = house.createEnglishAuction(address(nft), tokenId, reserve, 2 days);
        vm.stopPrank();
        englishIds.push(id);
    }

    function createDutch(uint256 seed, uint256 startPrice) external {
        address seller = _actor(seed);
        startPrice = bound(startPrice, 1 ether, 20 ether);
        vm.startPrank(seller);
        uint256 tokenId = nft.mint();
        nft.approve(address(house), tokenId);
        uint256 id = house.createDutchAuction(address(nft), tokenId, startPrice, startPrice / 2, 2 days);
        vm.stopPrank();
        dutchIds.push(id);
    }

    function bid(uint256 seed, uint256 idSeed, uint256 amount) external {
        if (englishIds.length == 0) return;
        uint256 id = englishIds[idSeed % englishIds.length];
        AuctionHouse.Auction memory a = house.getAuction(id);
        if (a.settled || block.timestamp >= a.end) return;

        uint256 floor = a.highestBidder == address(0) ? a.reservePrice : a.highestBid + house.MIN_INCREMENT();
        amount = bound(amount, floor, floor + 10 ether);
        address bidder = _actor(seed);
        if (bidder.balance < amount) return;
        vm.prank(bidder);
        house.bid{value: amount}(id);
    }

    function buyDutch(uint256 seed, uint256 idSeed) external {
        if (dutchIds.length == 0) return;
        uint256 id = dutchIds[idSeed % dutchIds.length];
        AuctionHouse.Auction memory a = house.getAuction(id);
        if (a.settled) return;
        uint256 price = house.currentPrice(id);
        address buyer = _actor(seed);
        if (buyer.balance < price) return;
        vm.prank(buyer);
        house.buy{value: price}(id);
    }

    function settle(uint256 idSeed) external {
        if (englishIds.length == 0) return;
        uint256 id = englishIds[idSeed % englishIds.length];
        AuctionHouse.Auction memory a = house.getAuction(id);
        if (a.settled || block.timestamp < a.end) return;
        house.settleEnglish(id);
    }

    function withdraw(uint256 seed) external {
        address actor = _actor(seed);
        if (house.balances(actor) == 0) return;
        vm.prank(actor);
        house.withdraw();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 3 days));
    }

    // Sum of ETH the house is still holding as live English high bids.
    function standingBids() external view returns (uint256 total) {
        for (uint256 i = 0; i < englishIds.length; i++) {
            AuctionHouse.Auction memory a = house.getAuction(englishIds[i]);
            if (!a.settled) total += a.highestBid;
        }
    }

    function owedBalances() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += house.balances(actors[i]);
        }
    }
}

contract AuctionHouseInvariantTest is Test {
    AuctionHouse internal house;
    AuctionableNFT internal nft;
    AuctionHandler internal handler;

    function setUp() public {
        house = new AuctionHouse();
        nft = new AuctionableNFT();
        handler = new AuctionHandler(house, nft);
        targetContract(address(handler));
    }

    /// @notice The house only ever holds ETH it owes: withdrawable balances
    ///         plus the escrowed high bids of still-live English auctions.
    ///         Any drift would mean ETH created or destroyed.
    function invariant_SolventForAllObligations() public view {
        assertEq(address(house).balance, handler.owedBalances() + handler.standingBids());
    }
}
