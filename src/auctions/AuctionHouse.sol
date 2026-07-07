// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionHouse
/// @notice Escrowed NFT auctions with pull-based payouts. This first cut hosts
///         English (ascending) auctions; Dutch auctions are added on top of the
///         same escrow + withdrawal machinery.
///
///         The load-bearing safety decision is pull over push payments: an
///         outbid bidder is *credited* a withdrawable balance rather than paid
///         inline. Paying inline would let a contract that reverts on receive
///         permanently block anyone from outbidding it (the King of the Ether
///         bug). Sellers and outbid bidders call withdraw() to collect.
contract AuctionHouse is IERC721Receiver, ReentrancyGuard {
    enum Kind {
        English,
        Dutch
    }

    struct Auction {
        Kind kind;
        bool settled;
        address seller;
        address nft;
        uint256 tokenId;
        uint40 start; // Dutch: decay start; English: unused
        uint40 end;
        // English
        uint256 reservePrice;
        address highestBidder;
        uint256 highestBid;
        // Dutch
        uint256 startPrice;
        uint256 floorPrice;
    }

    /// @notice Minimum a new bid must exceed the standing bid by.
    uint256 public constant MIN_INCREMENT = 0.01 ether;
    /// @notice A bid landing within this window of the end pushes the end out,
    ///         so an auction can't be won by sniping the final second.
    uint40 public constant EXTENSION_WINDOW = 15 minutes;

    Auction[] internal _auctions;

    /// @notice Pull-payment ledger: outbid refunds and seller proceeds accrue here.
    mapping(address => uint256) public balances;

    event EnglishAuctionCreated(
        uint256 indexed id, address indexed seller, address indexed nft, uint256 tokenId, uint256 reservePrice, uint40 end
    );
    event DutchAuctionCreated(
        uint256 indexed id, address indexed seller, address indexed nft, uint256 tokenId, uint256 startPrice, uint256 floorPrice, uint40 end
    );
    event BidPlaced(uint256 indexed id, address indexed bidder, uint256 amount, uint40 newEnd);
    event DutchBought(uint256 indexed id, address indexed buyer, uint256 price);
    event AuctionSettled(uint256 indexed id, address winner, uint256 amount);
    event AuctionCancelled(uint256 indexed id);
    event Withdrawal(address indexed account, uint256 amount);

    error ZeroDuration();
    error NotSeller();
    error AuctionAlreadySettled();
    error AuctionEnded();
    error AuctionNotEnded();
    error BidBelowReserve();
    error BidTooLow();
    error HasBids();
    error WrongAuctionKind();
    error NothingToWithdraw();
    error TransferFailed();
    error InvalidPriceRange();
    error InsufficientPayment();

    // ─── English auctions ───────────────────────────────────────────────────

    /// @notice Escrow an NFT and open an ascending auction. The seller must
    ///         approve this contract for the token first; it is pulled into
    ///         escrow here and released to the winner (or back to the seller)
    ///         at settlement.
    function createEnglishAuction(address nft, uint256 tokenId, uint256 reservePrice, uint40 duration)
        external
        returns (uint256 id)
    {
        if (duration == 0) revert ZeroDuration();

        id = _auctions.length;
        Auction storage a = _auctions.push();
        a.kind = Kind.English;
        a.seller = msg.sender;
        a.nft = nft;
        a.tokenId = tokenId;
        a.reservePrice = reservePrice;
        // forge-lint: disable-next-line(block-timestamp)
        a.end = uint40(block.timestamp) + duration;

        IERC721(nft).transferFrom(msg.sender, address(this), tokenId);
        emit EnglishAuctionCreated(id, msg.sender, nft, tokenId, reservePrice, a.end);
    }

    /// @notice Bid the full ETH amount you're willing to pay. The previous
    ///         high bidder's escrowed funds become withdrawable immediately.
    function bid(uint256 id) external payable nonReentrant {
        Auction storage a = _english(id);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= a.end) revert AuctionEnded();

        if (a.highestBidder == address(0)) {
            // Reject a zero bid even in a no-reserve auction: "no reserve"
            // means any positive bid wins, not that the NFT is free.
            if (msg.value == 0 || msg.value < a.reservePrice) revert BidBelowReserve();
        } else {
            if (msg.value < a.highestBid + MIN_INCREMENT) revert BidTooLow();
        }

        // Refund the outbid bidder via the pull-payment ledger (never inline).
        if (a.highestBidder != address(0)) {
            balances[a.highestBidder] += a.highestBid;
        }
        a.highestBidder = msg.sender;
        a.highestBid = msg.value;

        // Anti-snipe: extend the end if this bid arrived in the closing window.
        // forge-lint: disable-next-line(block-timestamp)
        uint40 minEnd = uint40(block.timestamp) + EXTENSION_WINDOW;
        if (a.end < minEnd) a.end = minEnd;

        emit BidPlaced(id, msg.sender, msg.value, a.end);
    }

    /// @notice After the auction ends, award the NFT to the winner and credit
    ///         the seller — or, if nobody bid, return the NFT to the seller.
    ///         Callable by anyone; settlement is mechanical.
    function settleEnglish(uint256 id) external nonReentrant {
        Auction storage a = _english(id);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < a.end) revert AuctionNotEnded();
        if (a.settled) revert AuctionAlreadySettled();

        a.settled = true;
        // settleEnglish is permissionless and the recipient (winner or seller)
        // is not the caller, so it must not be blockable. A plain transferFrom
        // skips onERC721Received: a recipient that can't receive safely only
        // affects its own future custody, it can't freeze the seller's
        // proceeds or the NFT in escrow.
        if (a.highestBidder != address(0)) {
            balances[a.seller] += a.highestBid;
            IERC721(a.nft).transferFrom(address(this), a.highestBidder, a.tokenId);
            emit AuctionSettled(id, a.highestBidder, a.highestBid);
        } else {
            IERC721(a.nft).transferFrom(address(this), a.seller, a.tokenId);
            emit AuctionSettled(id, address(0), 0);
        }
    }

    /// @notice Seller reclaims the NFT from an auction that never got a bid.
    ///         Guards against pulling an NFT out from under a live bid.
    function cancelAuction(uint256 id) external nonReentrant {
        Auction storage a = _auctionForCancel(id);
        if (msg.sender != a.seller) revert NotSeller();
        if (a.highestBidder != address(0)) revert HasBids();

        a.settled = true;
        IERC721(a.nft).safeTransferFrom(address(this), a.seller, a.tokenId);
        emit AuctionCancelled(id);
    }

    // ─── Dutch auctions ─────────────────────────────────────────────────────

    /// @notice Escrow an NFT and open a descending-price auction. The price
    ///         starts at startPrice and decays linearly to floorPrice over
    ///         `duration`, where it stays until someone buys.
    function createDutchAuction(
        address nft,
        uint256 tokenId,
        uint256 startPrice,
        uint256 floorPrice,
        uint40 duration
    ) external returns (uint256 id) {
        if (duration == 0) revert ZeroDuration();
        if (startPrice < floorPrice) revert InvalidPriceRange();

        id = _auctions.length;
        Auction storage a = _auctions.push();
        a.kind = Kind.Dutch;
        a.seller = msg.sender;
        a.nft = nft;
        a.tokenId = tokenId;
        a.startPrice = startPrice;
        a.floorPrice = floorPrice;
        // forge-lint: disable-next-line(block-timestamp)
        a.start = uint40(block.timestamp);
        // forge-lint: disable-next-line(block-timestamp)
        a.end = uint40(block.timestamp) + duration;

        IERC721(nft).transferFrom(msg.sender, address(this), tokenId);
        emit DutchAuctionCreated(id, msg.sender, nft, tokenId, startPrice, floorPrice, a.end);
    }

    /// @notice The price a buyer would pay right now: a straight-line decay
    ///         from startPrice at `start` to floorPrice at `end`, clamped at
    ///         floorPrice thereafter.
    function currentPrice(uint256 id) public view returns (uint256) {
        Auction storage a = _auctions[id];
        if (a.kind != Kind.Dutch) revert WrongAuctionKind();

        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= a.end) return a.floorPrice;
        uint256 elapsed = block.timestamp - a.start;
        uint256 span = a.end - a.start;
        uint256 drop = ((a.startPrice - a.floorPrice) * elapsed) / span;
        return a.startPrice - drop;
    }

    /// @notice Buy the NFT at (or above) the current price; the first taker
    ///         wins. Overpayment is refunded through the pull-payment ledger,
    ///         and the seller is credited the settled price.
    function buy(uint256 id) external payable nonReentrant {
        Auction storage a = _auctions[id];
        if (a.kind != Kind.Dutch) revert WrongAuctionKind();
        if (a.settled) revert AuctionAlreadySettled();

        uint256 price = currentPrice(id);
        if (msg.value < price) revert InsufficientPayment();

        a.settled = true;
        balances[a.seller] += price;
        if (msg.value > price) {
            balances[msg.sender] += msg.value - price; // refund excess, pull-style
        }

        IERC721(a.nft).safeTransferFrom(address(this), msg.sender, a.tokenId);
        emit DutchBought(id, msg.sender, price);
    }

    // ─── Payments ───────────────────────────────────────────────────────────

    /// @notice Pull out everything credited to you. Checks-effects-interactions:
    ///         the balance is zeroed before the transfer.
    function withdraw() external nonReentrant {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        balances[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawal(msg.sender, amount);
    }

    // ─── Views ──────────────────────────────────────────────────────────────

    function getAuction(uint256 id) external view returns (Auction memory) {
        return _auctions[id];
    }

    function auctionsCount() external view returns (uint256) {
        return _auctions.length;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ─── Internals ──────────────────────────────────────────────────────────

    function _english(uint256 id) internal view returns (Auction storage a) {
        a = _auctions[id];
        if (a.kind != Kind.English) revert WrongAuctionKind();
        if (a.settled) revert AuctionAlreadySettled();
    }

    function _auctionForCancel(uint256 id) internal view returns (Auction storage a) {
        a = _auctions[id];
        if (a.settled) revert AuctionAlreadySettled();
    }
}
