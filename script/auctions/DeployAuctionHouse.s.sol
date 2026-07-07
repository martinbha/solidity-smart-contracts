// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AuctionHouse} from "../../src/auctions/AuctionHouse.sol";
import {AuctionableNFT} from "../../src/auctions/AuctionableNFT.sol";

/// @notice Deploys the auction house + a sample NFT, mints two tokens to the
///         deployer, and opens one English and one Dutch auction so the utils
///         script has live auctions to drive.
contract DeployAuctionHouse is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        AuctionHouse house = new AuctionHouse();
        AuctionableNFT nft = new AuctionableNFT();

        uint256 englishToken = nft.mint();
        uint256 dutchToken = nft.mint();
        nft.approve(address(house), englishToken);
        nft.approve(address(house), dutchToken);

        uint256 englishId =
            house.createEnglishAuction(address(nft), englishToken, 1 ether, 1 days);
        uint256 dutchId =
            house.createDutchAuction(address(nft), dutchToken, 10 ether, 2 ether, 1 days);

        vm.stopBroadcast();

        console.log("AUCTION_HOUSE:", address(house));
        console.log("AUCTION_NFT:", address(nft));
        console.log("ENGLISH_AUCTION_ID:", englishId);
        console.log("ENGLISH_TOKEN_ID:", englishToken);
        console.log("DUTCH_AUCTION_ID:", dutchId);
        console.log("DUTCH_TOKEN_ID:", dutchToken);
    }
}
