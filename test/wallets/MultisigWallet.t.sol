// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MultisigWallet} from "../../src/wallets/MultisigWallet.sol";

contract Receiver {
    error Nope();

    bool public shouldRevert = true;
    uint256 public pokes;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function poke() external {
        if (shouldRevert) revert Nope();
        pokes++;
    }
}

contract MultisigWalletTest is Test {
    // secp256k1 group order, for crafting high-s (malleable) signatures.
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    MultisigWallet internal wallet;

    uint256[] internal ownerKeys;
    address[] internal owners;

    address internal recipient = makeAddr("recipient");
    uint256 internal nonOwnerKey = 0xBAD;

    function setUp() public {
        for (uint256 i = 1; i <= 3; i++) {
            ownerKeys.push(i);
            owners.push(vm.addr(i));
        }
        wallet = new MultisigWallet(owners, 2);
        vm.deal(address(wallet), 10 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _txn(address to, uint256 value, bytes memory data)
        internal
        view
        returns (MultisigWallet.Transaction memory)
    {
        return MultisigWallet.Transaction({to: to, value: value, data: data, nonce: wallet.nonce()});
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs `digest` with `keys` and returns the signatures sorted by
    ///      ascending signer address, as `execute` requires.
    function _signAll(uint256[] memory keys, bytes32 digest) internal pure returns (bytes[] memory sigs) {
        // Sort keys by signer address (insertion sort; tiny arrays).
        for (uint256 i = 1; i < keys.length; i++) {
            uint256 k = keys[i];
            uint256 j = i;
            while (j > 0 && vm.addr(keys[j - 1]) > vm.addr(k)) {
                keys[j] = keys[j - 1];
                j--;
            }
            keys[j] = k;
        }
        sigs = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            sigs[i] = _sign(keys[i], digest);
        }
    }

    function _twoKeys(uint256 a, uint256 b) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](2);
        keys[0] = a;
        keys[1] = b;
    }

    // ------------------------------------------------------------- happy path

    function test_executesWithExactlyThresholdSignatures() public {
        MultisigWallet.Transaction memory txn = _txn(recipient, 1 ether, "");
        bytes[] memory sigs = _signAll(_twoKeys(1, 2), wallet.txHash(txn));

        wallet.execute(txn, sigs);

        assertEq(recipient.balance, 1 ether);
        assertEq(wallet.nonce(), 1);
    }

    function test_anyoneCanSubmitTheSignedBundle() public {
        MultisigWallet.Transaction memory txn = _txn(recipient, 1 ether, "");
        bytes[] memory sigs = _signAll(_twoKeys(1, 2), wallet.txHash(txn));

        vm.prank(makeAddr("relayer"));
        wallet.execute(txn, sigs);

        assertEq(recipient.balance, 1 ether);
    }

    function test_receiveEmitsDeposit() public {
        vm.expectEmit(true, false, false, true, address(wallet));
        emit MultisigWallet.Deposited(address(this), 1 ether);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ---------------------------------------------------- signature rejection

    function test_revertsBelowThreshold() public {
        MultisigWallet.Transaction memory txn = _txn(recipient, 1 ether, "");
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(1, wallet.txHash(txn));

        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.NotEnoughSignatures.selector, 2, 1));
        wallet.execute(txn, sigs);
    }

    function test_revertsOnDuplicateSigner() public {
        MultisigWallet.Transaction memory txn = _txn(recipient, 1 ether, "");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(1, wallet.txHash(txn));
        sigs[1] = sigs[0];

        vm.expectRevert(MultisigWallet.UnsortedSigners.selector);
        wallet.execute(txn, sigs);
    }

    function test_revertsOnDescendingSignerOrder() public {
        MultisigWallet.Transaction memory txn = _txn(recipient, 1 ether, "");
        bytes[] memory sorted = _signAll(_twoKeys(1, 2), wallet.txHash(txn));
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (sorted[1], sorted[0]);

        vm.expectRevert(MultisigWallet.UnsortedSigners.selector);
        wallet.execute(txn, sigs);
    }

    function test_revertsOnNonOwnerSignature() public {
        MultisigWallet.Transaction memory txn = _txn(recipient, 1 ether, "");
        bytes[] memory sigs = _signAll(_twoKeys(1, nonOwnerKey), wallet.txHash(txn));

        vm.expectRevert(
            abi.encodeWithSelector(MultisigWallet.InvalidSigner.selector, vm.addr(nonOwnerKey))
        );
        wallet.execute(txn, sigs);
    }

    function test_rejectsHighSMalleatedSignature() public {
        MultisigWallet.Transaction memory txn = _txn(recipient, 1 ether, "");
        bytes32 digest = wallet.txHash(txn);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);

        // Flip into the high-s half of the curve — same signer under raw
        // ecrecover, but OZ ECDSA must reject it.
        bytes32 sHigh = bytes32(SECP256K1_N - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = abi.encodePacked(r, sHigh, vFlipped);
        sigs[1] = _sign(2, digest);

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sHigh));
        wallet.execute(txn, sigs);
    }

    // ------------------------------------------------------- replay & domains

    function test_bundleCannotBeReplayed() public {
        MultisigWallet.Transaction memory txn = _txn(recipient, 1 ether, "");
        bytes[] memory sigs = _signAll(_twoKeys(1, 2), wallet.txHash(txn));

        wallet.execute(txn, sigs);

        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.WrongNonce.selector, 1, 0));
        wallet.execute(txn, sigs);
    }

    function test_digestForWalletADoesNotExecuteOnWalletB() public {
        MultisigWallet walletB = new MultisigWallet(owners, 2);
        vm.deal(address(walletB), 10 ether);

        // Same owners, same nonce, same payload — signed against wallet A's
        // domain, so wallet B recovers different (non-owner) signers.
        MultisigWallet.Transaction memory txn = _txn(recipient, 1 ether, "");
        bytes[] memory sigs = _signAll(_twoKeys(1, 2), wallet.txHash(txn));

        vm.expectRevert();
        walletB.execute(txn, sigs);
        assertEq(recipient.balance, 0);
    }

    // ------------------------------------------------- failed inner call semantics

    function test_innerRevertBubblesAndPreservesNonce() public {
        Receiver target = new Receiver();
        MultisigWallet.Transaction memory txn =
            _txn(address(target), 0, abi.encodeCall(Receiver.poke, ()));
        bytes[] memory sigs = _signAll(_twoKeys(1, 2), wallet.txHash(txn));

        // Inner revert bubbles with its original reason and rolls back the
        // nonce bump: the approval is not silently burned.
        vm.expectRevert(Receiver.Nope.selector);
        wallet.execute(txn, sigs);
        assertEq(wallet.nonce(), 0);

        // Once conditions change, the very same signed bundle goes through.
        target.setShouldRevert(false);
        wallet.execute(txn, sigs);
        assertEq(target.pokes(), 1);
        assertEq(wallet.nonce(), 1);
    }

    // -------------------------------------------------------- owner management

    function test_adminFunctionsRevertWhenCalledDirectly() public {
        address newOwner = makeAddr("newOwner");

        vm.expectRevert(MultisigWallet.NotSelf.selector);
        wallet.addOwner(newOwner);

        vm.expectRevert(MultisigWallet.NotSelf.selector);
        wallet.removeOwner(owners[0]);

        vm.expectRevert(MultisigWallet.NotSelf.selector);
        wallet.changeThreshold(3);

        // Even an owner cannot call them directly.
        vm.prank(owners[0]);
        vm.expectRevert(MultisigWallet.NotSelf.selector);
        wallet.addOwner(newOwner);
    }

    function _executeSelfCall(bytes memory data) internal {
        MultisigWallet.Transaction memory txn = _txn(address(wallet), 0, data);
        wallet.execute(txn, _signAll(_twoKeys(1, 2), wallet.txHash(txn)));
    }

    function test_ownerManagementWorksThroughExecute() public {
        address newOwner = makeAddr("newOwner");

        _executeSelfCall(abi.encodeCall(MultisigWallet.addOwner, (newOwner)));
        assertTrue(wallet.isOwner(newOwner));
        assertEq(wallet.ownerCount(), 4);

        _executeSelfCall(abi.encodeCall(MultisigWallet.removeOwner, (newOwner)));
        assertFalse(wallet.isOwner(newOwner));
        assertEq(wallet.ownerCount(), 3);

        _executeSelfCall(abi.encodeCall(MultisigWallet.changeThreshold, (3)));
        assertEq(wallet.threshold(), 3);
    }

    function test_removingOwnerBelowThresholdReverts() public {
        // 3 owners, threshold 2: removing one is fine, removing a second
        // would leave 1 < 2 and must revert (bubbled through execute).
        _executeSelfCall(abi.encodeCall(MultisigWallet.removeOwner, (owners[2])));
        assertEq(wallet.ownerCount(), 2);

        MultisigWallet.Transaction memory txn =
            _txn(address(wallet), 0, abi.encodeCall(MultisigWallet.removeOwner, (owners[1])));
        bytes[] memory sigs = _signAll(_twoKeys(1, 2), wallet.txHash(txn));

        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.InvalidThreshold.selector, 2, 1));
        wallet.execute(txn, sigs);
    }

    // ------------------------------------------------------------ constructor

    function test_constructorValidatesInput() public {
        address[] memory two = new address[](2);
        (two[0], two[1]) = (owners[0], owners[1]);

        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.InvalidThreshold.selector, 0, 2));
        new MultisigWallet(two, 0);

        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.InvalidThreshold.selector, 3, 2));
        new MultisigWallet(two, 3);

        two[1] = two[0];
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.DuplicateOwner.selector, two[0]));
        new MultisigWallet(two, 2);

        two[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(MultisigWallet.InvalidOwner.selector, address(0)));
        new MultisigWallet(two, 2);
    }

    // ------------------------------------------------------------------- fuzz

    /// @dev Any subset of a 5-owner / threshold-3 wallet signs: subsets with
    ///      >= 3 owners execute, smaller ones revert.
    function testFuzz_subsetsAgainstThreshold(uint8 mask) public {
        uint256 n = 5;
        uint256 m = 3;

        uint256[] memory keys = new uint256[](n);
        address[] memory fuzzOwners = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            keys[i] = 100 + i;
            fuzzOwners[i] = vm.addr(keys[i]);
        }
        MultisigWallet fuzzWallet = new MultisigWallet(fuzzOwners, m);
        vm.deal(address(fuzzWallet), 1 ether);

        // Pick the subset of signing owners from the mask's low 5 bits.
        uint256 count;
        uint256[] memory subset = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (mask & (1 << i) != 0) subset[count++] = keys[i];
        }
        uint256[] memory signing = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            signing[i] = subset[i];
        }

        MultisigWallet.Transaction memory txn =
            MultisigWallet.Transaction({to: recipient, value: 1 wei, data: "", nonce: 0});
        bytes[] memory sigs = _signAll(signing, fuzzWallet.txHash(txn));

        if (count >= m) {
            fuzzWallet.execute(txn, sigs);
            assertEq(fuzzWallet.nonce(), 1);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(MultisigWallet.NotEnoughSignatures.selector, m, count)
            );
            fuzzWallet.execute(txn, sigs);
        }
    }
}
