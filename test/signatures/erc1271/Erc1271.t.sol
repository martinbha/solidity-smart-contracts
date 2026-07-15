// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SignerMultisig} from "../../../src/signatures/erc1271/SignerMultisig.sol";
import {OrderBook} from "../../../src/signatures/erc1271/OrderBook.sol";

contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A contract maker that does NOT implement EIP-1271.
contract NotASigner {}

contract Erc1271Test is Test {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    OrderBook internal book;
    TestToken internal token;
    SignerMultisig internal multisig;

    uint256[] internal ownerKeys;
    address[] internal owners;

    uint256 internal eoaMakerKey = 0xEEA;
    address internal eoaMaker;
    address internal taker = makeAddr("taker");

    function setUp() public {
        book = new OrderBook();
        token = new TestToken();

        // 2-of-3 signer multisig.
        for (uint256 i = 1; i <= 3; i++) {
            ownerKeys.push(i);
            owners.push(vm.addr(i));
        }
        multisig = new SignerMultisig(owners, 2);

        eoaMaker = vm.addr(eoaMakerKey);

        vm.deal(taker, 100 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _order(address maker, uint256 nonce) internal view returns (OrderBook.Order memory) {
        return OrderBook.Order({maker: maker, token: address(token), amount: 100 ether, price: 1 ether, nonce: nonce});
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs `digest` with `keys`, concatenated in ascending signer order
    ///      as `SignerMultisig` requires.
    function _multisigSig(uint256[] memory keys, bytes32 digest) internal pure returns (bytes memory sig) {
        // Insertion sort keys by signer address.
        for (uint256 i = 1; i < keys.length; i++) {
            uint256 k = keys[i];
            uint256 j = i;
            while (j > 0 && vm.addr(keys[j - 1]) > vm.addr(k)) {
                keys[j] = keys[j - 1];
                j--;
            }
            keys[j] = k;
        }
        for (uint256 i = 0; i < keys.length; i++) {
            sig = bytes.concat(sig, _sign(keys[i], digest));
        }
    }

    function _twoKeys(uint256 a, uint256 b) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](2);
        (keys[0], keys[1]) = (a, b);
    }

    function _prepareMaker(address maker) internal {
        token.mint(maker, 100 ether);
        vm.prank(maker);
        token.approve(address(book), 100 ether);
    }

    /// @dev Approves the book from the multisig the on-chain way: a
    ///      threshold-signed `execute` calling `token.approve`, so no prank
    ///      shortcut stands in for a real contract-maker approval.
    function _prepareMultisigMaker(uint256 amount) internal {
        token.mint(address(multisig), amount);

        bytes memory approveCall = abi.encodeCall(token.approve, (address(book), amount));
        bytes32 digest = multisig.hashExecute(address(token), 0, approveCall, multisig.nonce());
        bytes memory sig = _multisigSig(_twoKeys(1, 2), digest);

        multisig.execute(address(token), 0, approveCall, sig);
    }

    // --------------------------------------------------- isValidSignature unit

    function test_isValidSignatureReturnsMagicForThresholdBundle() public view {
        bytes32 hash = keccak256("hello");
        bytes memory sig = _multisigSig(_twoKeys(1, 2), hash);
        assertEq(multisig.isValidSignature(hash, sig), MAGIC_VALUE);
    }

    function test_isValidSignatureRejectsBelowThreshold() public view {
        bytes32 hash = keccak256("hello");
        bytes memory sig = _sign(1, hash); // only one owner
        assertEq(multisig.isValidSignature(hash, sig), INVALID);
    }

    function test_isValidSignatureRejectsNonOwner() public view {
        bytes32 hash = keccak256("hello");
        // Owner 1 plus a non-owner key.
        bytes memory sig = _multisigSig(_twoKeys(1, 0xBAD), hash);
        assertEq(multisig.isValidSignature(hash, sig), INVALID);
    }

    function test_isValidSignatureRejectsDuplicateSigner() public view {
        bytes32 hash = keccak256("hello");
        bytes memory sig = bytes.concat(_sign(1, hash), _sign(1, hash));
        assertEq(multisig.isValidSignature(hash, sig), INVALID);
    }

    function test_isValidSignatureRejectsUnsortedSigners() public view {
        bytes32 hash = keccak256("hello");
        bytes memory sorted = _multisigSig(_twoKeys(1, 2), hash);
        // Swap the two 65-byte halves out of order.
        bytes memory unsorted = bytes.concat(_slice(sorted, 65, 65), _slice(sorted, 0, 65));
        assertEq(multisig.isValidSignature(hash, unsorted), INVALID);
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[start + i];
        }
    }

    // ------------------------------------------------------- EOA-signed fills

    function test_fillsEoaSignedOrder() public {
        _prepareMaker(eoaMaker);
        OrderBook.Order memory order = _order(eoaMaker, 0);
        bytes memory sig = _sign(eoaMakerKey, book.hashOrder(order));

        vm.prank(taker);
        book.fillOrder{value: 1 ether}(order, sig);

        assertEq(token.balanceOf(taker), 100 ether);
        assertEq(eoaMaker.balance, 1 ether);
        assertTrue(book.filled(eoaMaker, 0));
    }

    function test_eoaOrderWithWrongSignerReverts() public {
        _prepareMaker(eoaMaker);
        OrderBook.Order memory order = _order(eoaMaker, 0);
        bytes memory sig = _sign(0xBAD, book.hashOrder(order));

        vm.prank(taker);
        vm.expectRevert(OrderBook.BadSignature.selector);
        book.fillOrder{value: 1 ether}(order, sig);
    }

    // -------------------------------------------------- multisig-signed fills

    function test_fillsMultisigSignedOrder() public {
        _prepareMultisigMaker(100 ether);
        OrderBook.Order memory order = _order(address(multisig), 0);
        bytes memory sig = _multisigSig(_twoKeys(1, 2), book.hashOrder(order));

        vm.prank(taker);
        book.fillOrder{value: 1 ether}(order, sig);

        assertEq(token.balanceOf(taker), 100 ether);
        assertEq(address(multisig).balance, 1 ether);
    }

    function test_rejectsBelowThresholdMultisigOrder() public {
        _prepareMultisigMaker(100 ether);
        OrderBook.Order memory order = _order(address(multisig), 0);
        // Only one owner signs — below the 2-of-3 threshold.
        bytes memory sig = _sign(1, book.hashOrder(order));

        vm.prank(taker);
        vm.expectRevert(OrderBook.BadSignature.selector);
        book.fillOrder{value: 1 ether}(order, sig);
    }

    // --------------------------------------------------- replay & tampering

    function test_orderReplayReverts() public {
        _prepareMaker(eoaMaker);
        token.mint(eoaMaker, 100 ether); // enough for a second fill if it got there
        vm.prank(eoaMaker);
        token.approve(address(book), 200 ether);

        OrderBook.Order memory order = _order(eoaMaker, 0);
        bytes memory sig = _sign(eoaMakerKey, book.hashOrder(order));

        vm.prank(taker);
        book.fillOrder{value: 1 ether}(order, sig);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.OrderAlreadyFilled.selector, eoaMaker, 0));
        book.fillOrder{value: 1 ether}(order, sig);
    }

    function test_tamperedOrderFailsVerification() public {
        _prepareMaker(eoaMaker);
        OrderBook.Order memory order = _order(eoaMaker, 0);
        bytes memory sig = _sign(eoaMakerKey, book.hashOrder(order));

        // Taker tries to fill for a larger amount than the maker signed.
        order.amount = 500 ether;

        vm.prank(taker);
        vm.expectRevert(OrderBook.BadSignature.selector);
        book.fillOrder{value: 1 ether}(order, sig);
    }

    // ----------------------------------------- non-1271 contract maker

    function test_contractMakerWithoutIsValidSignatureRejectedCleanly() public {
        NotASigner dummy = new NotASigner();
        _prepareMaker(address(dummy));
        OrderBook.Order memory order = _order(address(dummy), 0);
        // Any bytes; the maker has no isValidSignature to accept them.
        bytes memory sig = _multisigSig(_twoKeys(1, 2), book.hashOrder(order));

        vm.prank(taker);
        vm.expectRevert(OrderBook.BadSignature.selector);
        book.fillOrder{value: 1 ether}(order, sig);
    }

    // ------------------------------------------------- threshold execution

    function test_executeRunsCallWithThresholdSignatures() public {
        // A threshold-signed execute lets the multisig act: here, approve the
        // book, which a pure signer could never do on its own.
        bytes memory approveCall = abi.encodeCall(token.approve, (address(book), 50 ether));
        bytes32 digest = multisig.hashExecute(address(token), 0, approveCall, 0);
        bytes memory sig = _multisigSig(_twoKeys(1, 2), digest);

        multisig.execute(address(token), 0, approveCall, sig);

        assertEq(token.allowance(address(multisig), address(book)), 50 ether);
        assertEq(multisig.nonce(), 1);
    }

    function test_executeRevertsBelowThreshold() public {
        bytes memory approveCall = abi.encodeCall(token.approve, (address(book), 50 ether));
        bytes32 digest = multisig.hashExecute(address(token), 0, approveCall, 0);
        bytes memory sig = _sign(1, digest); // one owner only

        vm.expectRevert(SignerMultisig.NotEnoughSignatures.selector);
        multisig.execute(address(token), 0, approveCall, sig);
    }

    function test_executeBundleCannotBeReplayed() public {
        bytes memory approveCall = abi.encodeCall(token.approve, (address(book), 50 ether));
        bytes32 digest = multisig.hashExecute(address(token), 0, approveCall, 0);
        bytes memory sig = _multisigSig(_twoKeys(1, 2), digest);

        multisig.execute(address(token), 0, approveCall, sig);

        // Nonce advanced, so the same signed bundle no longer authorizes.
        vm.expectRevert(SignerMultisig.NotEnoughSignatures.selector);
        multisig.execute(address(token), 0, approveCall, sig);
    }

    // ------------------------------------------------------------------- fuzz

    /// @dev Random owner subsets of a 5-of... multisig: the bundle is valid
    ///      iff at least `threshold` distinct owners signed.
    function testFuzz_multisigValidIffThresholdMet(uint8 mask) public {
        uint256 n = 5;
        uint256 m = 3;
        uint256[] memory keys = new uint256[](n);
        address[] memory fuzzOwners = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            keys[i] = 100 + i;
            fuzzOwners[i] = vm.addr(keys[i]);
        }
        SignerMultisig fuzzSig = new SignerMultisig(fuzzOwners, m);

        // Select the signing subset from the mask's low 5 bits.
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            if (mask & (1 << i) != 0) count++;
        }
        uint256[] memory signing = new uint256[](count);
        uint256 next;
        for (uint256 i = 0; i < n; i++) {
            if (mask & (1 << i) != 0) signing[next++] = keys[i];
        }

        bytes32 hash = keccak256(abi.encodePacked("fuzz", mask));
        bytes memory sig = _multisigSig(signing, hash);

        bytes4 result = fuzzSig.isValidSignature(hash, sig);
        if (count >= m) {
            assertEq(result, MAGIC_VALUE);
        } else {
            assertEq(result, INVALID);
        }
    }
}
