// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC6551Registry} from "../../../src/nft/erc6551/ERC6551Registry.sol";
import {TokenBoundAccount} from "../../../src/nft/erc6551/TokenBoundAccount.sol";
import {ProfileNFT} from "../../../src/nft/erc6551/ProfileNFT.sol";

contract TokenBoundTest is Test {
    ERC6551Registry internal registry;
    TokenBoundAccount internal implementation;
    ProfileNFT internal profile;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant SALT = bytes32(uint256(1));
    uint256 internal tokenId;
    TokenBoundAccount internal account;

    function setUp() public {
        registry = new ERC6551Registry();
        implementation = new TokenBoundAccount();
        profile = new ProfileNFT();

        tokenId = profile.mint(alice);
        account = TokenBoundAccount(
            payable(registry.createAccount(address(implementation), SALT, block.chainid, address(profile), tokenId))
        );
    }

    function test_predictionMatchesDeployment() public view {
        address predicted = registry.account(address(implementation), SALT, block.chainid, address(profile), tokenId);

        assertEq(predicted, address(account));
        assertGt(predicted.code.length, 0);
    }

    function test_redeploymentIsIdempotent() public {
        bytes32 codehashBefore = address(account).codehash;

        address repeated =
            registry.createAccount(address(implementation), SALT, block.chainid, address(profile), tokenId);

        assertEq(repeated, address(account));
        assertEq(repeated.codehash, codehashBefore);
    }

    function test_tokenTupleComesFromProxyFooter() public view {
        (uint256 chainId, address tokenContract, uint256 boundTokenId) = account.token();

        assertEq(chainId, block.chainid);
        assertEq(tokenContract, address(profile));
        assertEq(boundTokenId, tokenId);
    }

    function test_ownerTracksNftTransfer() public {
        assertEq(account.owner(), alice);

        vm.prank(alice);
        profile.transferFrom(alice, bob, tokenId);

        assertEq(account.owner(), bob);
    }
}
