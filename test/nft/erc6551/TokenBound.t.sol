// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC6551Registry} from "../../../src/nft/erc6551/ERC6551Registry.sol";
import {
    IERC6551Account,
    IERC6551Executable,
    ISimpleTokenBoundExecutable,
    TokenBoundAccount
} from "../../../src/nft/erc6551/TokenBoundAccount.sol";
import {ProfileNFT} from "../../../src/nft/erc6551/ProfileNFT.sol";

contract AccountAsset is ERC20 {
    constructor() ERC20("Account Asset", "ASSET") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EquipmentNFT is ERC721 {
    uint256 public nextTokenId = 1;

    constructor() ERC721("Equipment", "GEAR") {}

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _safeMint(to, tokenId);
    }
}

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
        account.execute(address(recorder), 0, abi.encodeCall(recorder.record, (keccak256("blocked"))));
    }

    function test_transferRevokesPreviousOwnerAndAuthorizesNewOwner() public {
        vm.prank(alice);
        profile.transferFrom(alice, bob, tokenId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenBoundAccount.InvalidSigner.selector, alice));
        account.execute(address(recorder), 0, abi.encodeCall(recorder.record, (keccak256("old owner"))));

        vm.prank(bob);
        account.execute(address(recorder), 0, abi.encodeCall(recorder.record, (keccak256("new owner"))));

        assertEq(recorder.recorded(), keccak256("new owner"));
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

    function test_accountHoldsAndSendsErc20() public {
        AccountAsset asset = new AccountAsset();
        asset.mint(address(account), 100 ether);

        vm.prank(alice);
        account.execute(address(asset), 0, abi.encodeCall(asset.transfer, (bob, 40 ether)));

        assertEq(asset.balanceOf(address(account)), 60 ether);
        assertEq(asset.balanceOf(bob), 40 ether);
    }

    function test_accountSafelyReceivesAndSendsErc721() public {
        EquipmentNFT equipment = new EquipmentNFT();
        uint256 equipmentId = equipment.mint(address(account));
        assertEq(equipment.ownerOf(equipmentId), address(account));

        vm.prank(alice);
        account.execute(
            address(equipment),
            0,
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(account), bob, equipmentId)
        );

        assertEq(equipment.ownerOf(equipmentId), bob);
    }

    function test_accountCannotAcquireItsControllingNftThroughExecute() public {
        vm.prank(alice);
        profile.approve(address(account), tokenId);

        vm.prank(alice);
        vm.expectRevert(TokenBoundAccount.OwnershipCycle.selector);
        account.execute(
            address(profile),
            0,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, address(account), tokenId)
        );

        assertEq(profile.ownerOf(tokenId), alice);
    }

    function testFuzz_distinctTokenIdsHaveDistinctPredictedAccounts(uint256 firstId, uint256 secondId) public {
        vm.assume(firstId != secondId);

        address firstPredicted =
            registry.account(address(implementation), SALT, block.chainid, address(profile), firstId);
        address secondPredicted =
            registry.account(address(implementation), SALT, block.chainid, address(profile), secondId);

        address firstDeployed =
            registry.createAccount(address(implementation), SALT, block.chainid, address(profile), firstId);
        address secondDeployed =
            registry.createAccount(address(implementation), SALT, block.chainid, address(profile), secondId);

        assertEq(firstDeployed, firstPredicted);
        assertEq(secondDeployed, secondPredicted);
        assertNotEq(firstDeployed, secondDeployed);
    }

    function test_accountSignalsSupportedInterfaces() public view {
        assertTrue(account.supportsInterface(type(IERC165).interfaceId));
        assertTrue(account.supportsInterface(type(IERC6551Account).interfaceId));
        assertTrue(account.supportsInterface(type(IERC6551Executable).interfaceId));
        assertTrue(account.supportsInterface(type(ISimpleTokenBoundExecutable).interfaceId));
        assertFalse(account.supportsInterface(0xffffffff));
    }

    function test_foreignChainAccountDoesNotAuthorizeZeroAddress() public {
        TokenBoundAccount foreignAccount = TokenBoundAccount(
            payable(registry.createAccount(address(implementation), SALT, block.chainid + 1, address(profile), tokenId))
        );

        assertEq(foreignAccount.owner(), address(0));
        assertEq(foreignAccount.isValidSigner(address(0), ""), bytes4(0));
    }

    function test_standardExecuteOverloadSupportsCallOnly() public {
        vm.prank(alice);
        account.execute(address(recorder), 0, abi.encodeCall(recorder.record, (keccak256("standard"))), 0);
        assertEq(recorder.recorded(), keccak256("standard"));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenBoundAccount.UnsupportedOperation.selector, 1));
        account.execute(address(recorder), 0, abi.encodeCall(recorder.record, (keccak256("delegate"))), 1);
    }
}
