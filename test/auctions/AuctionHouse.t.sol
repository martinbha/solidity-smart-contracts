// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AuctionHouse} from "../../src/auctions/AuctionHouse.sol";
import {AuctionableNFT} from "../../src/auctions/AuctionableNFT.sol";

contract AuctionHouseTest is Test {
    AuctionHouse internal house;
    AuctionableNFT internal nft;

    address internal seller = makeAddr("seller");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint40 internal constant DURATION = 3 days;

    function setUp() public {
        house = new AuctionHouse();
        nft = new AuctionableNFT();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _mintAndList(uint256 reserve) internal returns (uint256 id, uint256 tokenId) {
        vm.startPrank(seller);
        tokenId = nft.mint();
        nft.approve(address(house), tokenId);
        id = house.createEnglishAuction(address(nft), tokenId, reserve, DURATION);
        vm.stopPrank();
    }

    function _mintAndListDutch(uint256 startPrice, uint256 floorPrice)
        internal
        returns (uint256 id, uint256 tokenId)
    {
        vm.startPrank(seller);
        tokenId = nft.mint();
        nft.approve(address(house), tokenId);
        id = house.createDutchAuction(address(nft), tokenId, startPrice, floorPrice, DURATION);
        vm.stopPrank();
    }

    // ─── English ────────────────────────────────────────────────────────────

    function test_English_HighestBidderWins() public {
        (uint256 id, uint256 tokenId) = _mintAndList(1 ether);

        vm.prank(alice);
        house.bid{value: 1 ether}(id);
        vm.prank(bob);
        house.bid{value: 2 ether}(id);

        // Alice was outbid: her 1 ETH is immediately withdrawable.
        assertEq(house.balances(alice), 1 ether);

        vm.warp(block.timestamp + DURATION);
        house.settleEnglish(id);

        assertEq(nft.ownerOf(tokenId), bob);
        assertEq(house.balances(seller), 2 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        house.withdraw();
        assertEq(alice.balance, before + 1 ether);
    }

    function test_English_RevertWhen_BidBelowReserve() public {
        (uint256 id,) = _mintAndList(5 ether);
        vm.expectRevert(AuctionHouse.BidBelowReserve.selector);
        vm.prank(alice);
        house.bid{value: 4 ether}(id);
    }

    function test_English_RevertWhen_BidBelowMinIncrement() public {
        (uint256 id,) = _mintAndList(1 ether);
        vm.prank(alice);
        house.bid{value: 1 ether}(id);

        vm.expectRevert(AuctionHouse.BidTooLow.selector);
        vm.prank(bob);
        house.bid{value: 1 ether + 0.005 ether}(id); // below MIN_INCREMENT over
    }

    function test_English_MaliciousBidderCannotBlockOutbids() public {
        (uint256 id,) = _mintAndList(1 ether);
        RevertingBidder attacker = new RevertingBidder(house);
        vm.deal(address(attacker), 10 ether);

        attacker.bid(id, 1 ether); // attacker is the standing high bid

        // Refunding the attacker inline would revert; pull payments mean bob
        // outbids fine and the attacker's refund just sits unclaimed.
        vm.prank(bob);
        house.bid{value: 2 ether}(id);

        assertEq(house.balances(address(attacker)), 1 ether);
        AuctionHouse.Auction memory a = house.getAuction(id);
        assertEq(a.highestBidder, bob);
    }

    function test_English_SettlementNotBlockedByBadReceiver() public {
        // A winner contract with no onERC721Received must not be able to freeze
        // settlement (and thus the seller's proceeds) forever.
        (uint256 id, uint256 tokenId) = _mintAndList(1 ether);
        NonReceiverBidder winner = new NonReceiverBidder(house);
        vm.deal(address(winner), 5 ether);
        winner.bid(id, 2 ether);

        vm.warp(block.timestamp + DURATION);
        house.settleEnglish(id); // would revert if delivery used safeTransferFrom

        assertEq(nft.ownerOf(tokenId), address(winner));
        assertEq(house.balances(seller), 2 ether);
    }

    function test_English_RevertWhen_ZeroBidOnNoReserveAuction() public {
        (uint256 id,) = _mintAndList(0); // no reserve
        vm.expectRevert(AuctionHouse.BidBelowReserve.selector);
        vm.prank(alice);
        house.bid{value: 0}(id);

        // A positive bid still wins a no-reserve auction.
        vm.prank(alice);
        house.bid{value: 1 wei}(id);
        AuctionHouse.Auction memory a = house.getAuction(id);
        assertEq(a.highestBidder, alice);
    }

    function test_English_LateBidExtendsDeadline() public {
        (uint256 id,) = _mintAndList(1 ether);
        AuctionHouse.Auction memory before = house.getAuction(id);

        // Warp to 5 minutes before the end, inside the 15-minute window.
        vm.warp(before.end - 5 minutes);
        vm.prank(alice);
        house.bid{value: 1 ether}(id);

        AuctionHouse.Auction memory a = house.getAuction(id);
        assertEq(a.end, uint40(block.timestamp) + house.EXTENSION_WINDOW());
        assertGt(a.end, before.end);
    }

    function test_English_RevertWhen_SettleBeforeEnd() public {
        (uint256 id,) = _mintAndList(1 ether);
        vm.prank(alice);
        house.bid{value: 1 ether}(id);

        vm.expectRevert(AuctionHouse.AuctionNotEnded.selector);
        house.settleEnglish(id);
    }

    function test_English_NoBids_ReturnsNftToSeller() public {
        (uint256 id, uint256 tokenId) = _mintAndList(1 ether);
        vm.warp(block.timestamp + DURATION);
        house.settleEnglish(id);
        assertEq(nft.ownerOf(tokenId), seller);
    }

    function test_CancelNoBidAuctionReturnsNft() public {
        (uint256 id, uint256 tokenId) = _mintAndList(1 ether);
        vm.prank(seller);
        house.cancelAuction(id);
        assertEq(nft.ownerOf(tokenId), seller);
    }

    function test_RevertWhen_CancelAfterBids() public {
        (uint256 id,) = _mintAndList(1 ether);
        vm.prank(alice);
        house.bid{value: 1 ether}(id);

        vm.expectRevert(AuctionHouse.HasBids.selector);
        vm.prank(seller);
        house.cancelAuction(id);
    }

    // ─── Dutch ──────────────────────────────────────────────────────────────

    function test_Dutch_PriceDecaysLinearlyAndClampsAtFloor() public {
        (uint256 id,) = _mintAndListDutch(10 ether, 2 ether);
        uint256 start = block.timestamp;

        assertEq(house.currentPrice(id), 10 ether); // t=0
        vm.warp(start + DURATION / 2);
        assertEq(house.currentPrice(id), 6 ether); // halfway: (10+2)/2
        vm.warp(start + DURATION);
        assertEq(house.currentPrice(id), 2 ether); // floor
        vm.warp(start + DURATION * 2);
        assertEq(house.currentPrice(id), 2 ether); // clamped past end
    }

    function test_Dutch_BuyAtCurrentPriceWins() public {
        (uint256 id, uint256 tokenId) = _mintAndListDutch(10 ether, 2 ether);
        vm.warp(block.timestamp + DURATION / 2); // price = 6 ether

        vm.prank(alice);
        house.buy{value: 6 ether}(id);

        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(house.balances(seller), 6 ether);
    }

    function test_Dutch_OverpaymentRefunded() public {
        (uint256 id,) = _mintAndListDutch(10 ether, 2 ether);
        vm.warp(block.timestamp + DURATION / 2); // price = 6 ether

        vm.prank(alice);
        house.buy{value: 10 ether}(id);

        assertEq(house.balances(seller), 6 ether);
        assertEq(house.balances(alice), 4 ether); // refund
    }

    function test_Dutch_RevertWhen_SecondBuyer() public {
        (uint256 id,) = _mintAndListDutch(10 ether, 2 ether);
        vm.prank(alice);
        house.buy{value: 10 ether}(id);

        vm.expectRevert(AuctionHouse.AuctionAlreadySettled.selector);
        vm.prank(bob);
        house.buy{value: 10 ether}(id);
    }

    function test_Dutch_RevertWhen_PaymentBelowPrice() public {
        (uint256 id,) = _mintAndListDutch(10 ether, 2 ether);
        vm.expectRevert(AuctionHouse.InsufficientPayment.selector);
        vm.prank(alice);
        house.buy{value: 9 ether}(id); // price is 10 at t=0
    }

    function test_Dutch_RevertWhen_InvalidPriceRange() public {
        vm.startPrank(seller);
        uint256 tokenId = nft.mint();
        nft.approve(address(house), tokenId);
        vm.expectRevert(AuctionHouse.InvalidPriceRange.selector);
        house.createDutchAuction(address(nft), tokenId, 1 ether, 2 ether, DURATION);
        vm.stopPrank();
    }

    // ─── Cross-kind guards ──────────────────────────────────────────────────

    function test_RevertWhen_BiddingOnDutch() public {
        (uint256 id,) = _mintAndListDutch(10 ether, 2 ether);
        vm.expectRevert(AuctionHouse.WrongAuctionKind.selector);
        vm.prank(alice);
        house.bid{value: 10 ether}(id);
    }

    function test_RevertWhen_BuyingEnglish() public {
        (uint256 id,) = _mintAndList(1 ether);
        vm.expectRevert(AuctionHouse.WrongAuctionKind.selector);
        vm.prank(alice);
        house.buy{value: 1 ether}(id);
    }

    function test_RevertWhen_WithdrawNothing() public {
        vm.expectRevert(AuctionHouse.NothingToWithdraw.selector);
        vm.prank(alice);
        house.withdraw();
    }
}

/// @dev A bidder contract that reverts on receiving ETH — used to prove that
///      inline refunds would brick the auction, but pull payments don't.
contract RevertingBidder {
    AuctionHouse private immutable house;

    constructor(AuctionHouse house_) {
        house = house_;
    }

    function bid(uint256 id, uint256 amount) external {
        house.bid{value: amount}(id);
    }

    receive() external payable {
        revert("no refunds accepted");
    }
}

/// @dev A bidder contract that can win but does NOT implement onERC721Received,
///      so a safeTransferFrom to it would revert. Used to prove settlement
///      delivers via transferFrom and can't be blocked by the winner.
contract NonReceiverBidder {
    AuctionHouse private immutable house;

    constructor(AuctionHouse house_) {
        house = house_;
    }

    function bid(uint256 id, uint256 amount) external {
        house.bid{value: amount}(id);
    }
}
