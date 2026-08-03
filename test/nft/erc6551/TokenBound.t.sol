// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC6551Registry} from "../../../src/nft/erc6551/ERC6551Registry.sol";
import {TokenBoundAccount} from "../../../src/nft/erc6551/TokenBoundAccount.sol";
import {ProfileNFT} from "../../../src/nft/erc6551/ProfileNFT.sol";

contract CallRecorder {
    address public caller;
    bytes32 public recorded;

    function record(bytes32 value) external payable returns (uint256) {
        caller = msg.sender;
        recorded = value;
        return 42;
    }
}

contract TokenBoundTest is Test {
    ERC6551Registry internal registry;
    TokenBoundAccount internal implementation;
    ProfileNFT internal profile;
    CallRecorder internal recorder;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant SALT = bytes32(uint256(1));
    uint256 internal tokenId;
    TokenBoundAccount internal account;

    function setUp() public {
        registry = new ERC6551Registry();
        implementation = new TokenBoundAccount();
        profile = new ProfileNFT();
        recorder = new CallRecorder();

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

    function test_ownerCanExecuteFromAccount() public {
        bytes32 expected = keccak256("profile action");

        vm.prank(alice);
        bytes memory result = account.execute(address(recorder), 0, abi.encodeCall(recorder.record, (expected)));

        assertEq(abi.decode(result, (uint256)), 42);
        assertEq(recorder.caller(), address(account));
        assertEq(recorder.recorded(), expected);
        assertEq(account.state(), 1);
    }

    function test_nonOwnerCannotExecute() public {
        address intruder = makeAddr("intruder");

        vm.prank(intruder);
        vm.expectRevert(abi.encodeWithSelector(TokenBoundAccount.InvalidSigner.selector, intruder));
        account.execute(address(recorder), 0, abi.encodeCall(recorder.record, (bytes32("blocked"))));
    }

    function test_transferRevokesPreviousOwnerAndAuthorizesNewOwner() public {
        vm.prank(alice);
        profile.transferFrom(alice, bob, tokenId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenBoundAccount.InvalidSigner.selector, alice));
        account.execute(address(recorder), 0, abi.encodeCall(recorder.record, (bytes32("old owner"))));

        vm.prank(bob);
        account.execute(address(recorder), 0, abi.encodeCall(recorder.record, (bytes32("new owner"))));

        assertEq(recorder.recorded(), bytes32("new owner"));
    }

    function test_accountReceivesAndSendsEther() public {
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        (bool funded,) = address(account).call{value: 2 ether}("");
        assertTrue(funded);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(alice);
        account.execute(bob, 0.75 ether, "");

        assertEq(address(account).balance, 1.25 ether);
        assertEq(bob.balance, bobBalanceBefore + 0.75 ether);
    }
}
