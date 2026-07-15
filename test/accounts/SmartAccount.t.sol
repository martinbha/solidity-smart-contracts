// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SmartAccount} from "../../src/accounts/SmartAccount.sol";
import {SmartAccountFactory} from "../../src/accounts/SmartAccountFactory.sol";
import {SponsorPaymaster} from "../../src/accounts/SponsorPaymaster.sol";

/// @dev A trivial target the smart account calls through the EntryPoint.
contract Counter {
    uint256 public count;
    mapping(address => uint256) public countBy;

    function increment() external {
        count++;
        countBy[msg.sender]++;
    }

    function boom() external pure {
        revert("Counter: boom");
    }
}

contract SmartAccountTest is Test {
    EntryPoint internal entryPoint;
    SmartAccountFactory internal factory;
    SponsorPaymaster internal paymaster;
    Counter internal counter;

    uint256 internal ownerKey = 0xA11CE;
    address internal owner;
    SmartAccount internal account;

    address internal bundler = makeAddr("bundler");

    // Packed gas limits/fees the EntryPoint expects (verificationGasLimit <<
    // 128 | callGasLimit, and maxPriorityFee << 128 | maxFee).
    bytes32 internal constant GAS_LIMITS = bytes32((uint256(600_000) << 128) | uint256(400_000));
    bytes32 internal constant GAS_FEES = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));

    function setUp() public {
        owner = vm.addr(ownerKey);
        entryPoint = new EntryPoint();
        factory = new SmartAccountFactory(IEntryPoint(address(entryPoint)));
        paymaster = new SponsorPaymaster(IEntryPoint(address(entryPoint)));
        counter = new Counter();

        account = factory.createAccount(owner, 0);
        // Fund the account so it can pay its own prefund in the non-sponsored
        // tests. Paymaster-sponsored tests leave the account at zero ETH.
        vm.deal(address(account), 10 ether);

        // Stake the paymaster's gas deposit and allowlist the counter.
        paymaster.deposit{value: 10 ether}();
        paymaster.setAllowed(address(counter), true);
    }

    // ---------------------------------------------------------------- helpers

    function _emptyOp(address sender) internal pure returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.accountGasLimits = GAS_LIMITS;
        op.gasFees = GAS_FEES;
        op.preVerificationGas = 60_000;
    }

    function _sign(uint256 key, PackedUserOperation memory op) internal view returns (PackedUserOperation memory) {
        bytes32 hash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        op.signature = abi.encodePacked(r, s, v);
        return op;
    }

    function _incrementCallData() internal view returns (bytes memory) {
        return abi.encodeCall(BaseAccount.execute, (address(counter), 0, abi.encodeCall(Counter.increment, ())));
    }

    function _handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler);
        entryPoint.handleOps(ops, payable(bundler));
    }

    /// @dev Attach the sponsoring paymaster to an op (verification/postOp gas
    ///      limits packed into paymasterAndData per the v0.8 layout).
    function _withPaymaster(PackedUserOperation memory op) internal view returns (PackedUserOperation memory) {
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(200_000), uint128(100_000));
        return op;
    }

    // ------------------------------------------------------------ happy path

    function test_validUserOpExecutesTheIntendedCall() public {
        PackedUserOperation memory op = _emptyOp(address(account));
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = _incrementCallData();
        op = _sign(ownerKey, op);

        _handle(op);

        assertEq(counter.count(), 1);
        assertEq(counter.countBy(address(account)), 1);
    }

    function test_ownerCanCallExecuteDirectly() public {
        vm.prank(owner);
        account.execute(address(counter), 0, abi.encodeCall(Counter.increment, ()));
        assertEq(counter.count(), 1);
    }

    function test_randomCallerCannotExecute() public {
        vm.prank(makeAddr("intruder"));
        vm.expectRevert("SmartAccount: not owner or EntryPoint");
        account.execute(address(counter), 0, abi.encodeCall(Counter.increment, ()));
    }

    // -------------------------------------------------------- signature gate

    function test_badSignatureIsRejectedByEntryPoint() public {
        PackedUserOperation memory op = _emptyOp(address(account));
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = _incrementCallData();
        // Sign with the wrong key: validateUserOp returns SIG_VALIDATION_FAILED,
        // which the EntryPoint reports as AA24 signature error.
        op = _sign(0xBAD, op);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        entryPoint.handleOps(ops, payable(bundler));

        assertEq(counter.count(), 0);
    }

    // ------------------------------------------------------- counterfactual

    function test_counterfactualAddressMatchesAndDeploysViaInitCode() public {
        uint256 salt = 42;
        address predicted = factory.getAddress(owner, salt);
        assertEq(predicted.code.length, 0, "should not exist yet");

        // Fund the counterfactual address before it is deployed — the whole
        // point of a known-in-advance address.
        vm.deal(predicted, 1 ether);

        PackedUserOperation memory op = _emptyOp(predicted);
        op.nonce = entryPoint.getNonce(predicted, 0);
        op.initCode = abi.encodePacked(address(factory), abi.encodeCall(factory.createAccount, (owner, salt)));
        op.callData = _incrementCallData();
        // The verification gas budget must also cover deploying the account
        // from initCode, so give this op extra headroom.
        op.accountGasLimits = bytes32((uint256(2_000_000) << 128) | uint256(400_000));
        op = _sign(ownerKey, op);

        _handle(op);

        assertGt(predicted.code.length, 0, "account deployed on first op");
        assertEq(SmartAccount(payable(predicted)).owner(), owner);
        assertEq(counter.count(), 1);
    }

    // ------------------------------------------------------------ paymaster

    function test_paymasterSponsorsGasSenderPaysNothing() public {
        // A brand-new account with zero ETH — it cannot pay its own prefund,
        // so only a paymaster can get its op included.
        uint256 poorKey = uint256(keccak256("poorOwner"));
        SmartAccount poor = factory.createAccount(vm.addr(poorKey), 8);
        assertEq(address(poor).balance, 0);

        uint256 paymasterDepositBefore = entryPoint.balanceOf(address(paymaster));

        PackedUserOperation memory op = _emptyOp(address(poor));
        op.nonce = entryPoint.getNonce(address(poor), 0);
        op.callData = _incrementCallData();
        op = _withPaymaster(op);
        op = _sign(poorKey, op);

        _handle(op);

        assertEq(counter.count(), 1);
        assertEq(address(poor).balance, 0, "sender spent no ETH");
        assertLt(entryPoint.balanceOf(address(paymaster)), paymasterDepositBefore, "paymaster deposit covered the gas");
    }

    function test_paymasterRejectsOpsOutsideItsAllowlist() public {
        Counter other = new Counter(); // not allowlisted

        PackedUserOperation memory op = _emptyOp(address(account));
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = abi.encodeCall(BaseAccount.execute, (address(other), 0, abi.encodeCall(Counter.increment, ())));
        op = _withPaymaster(op);
        op = _sign(ownerKey, op);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler);
        // Paymaster reverts in validation → EntryPoint surfaces AA33.
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                0,
                "AA33 reverted",
                abi.encodeWithSelector(SponsorPaymaster.TargetNotAllowed.selector, address(other))
            )
        );
        entryPoint.handleOps(ops, payable(bundler));
    }

    function test_paymasterRejectsShortCallDataWithoutPanic() public {
        // A deploy-only op (empty callData) sponsored by the paymaster: the
        // paymaster has no target to check, so it must reject cleanly rather
        // than panic on the calldata slice.
        PackedUserOperation memory op = _emptyOp(address(account));
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = ""; // shorter than a 4-byte selector
        op = _withPaymaster(op);
        op = _sign(ownerKey, op);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                0,
                "AA33 reverted",
                abi.encodeWithSelector(SponsorPaymaster.UnsupportedSelector.selector, bytes4(0))
            )
        );
        entryPoint.handleOps(ops, payable(bundler));
    }

    // -------------------------------------------------------------- batching

    function test_executeBatchPerformsMultipleCallsAtomically() public {
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](3);
        for (uint256 i = 0; i < 3; i++) {
            calls[i] =
                BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});
        }

        PackedUserOperation memory op = _emptyOp(address(account));
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = abi.encodeCall(BaseAccount.executeBatch, (calls));
        op = _sign(ownerKey, op);

        _handle(op);
        assertEq(counter.count(), 3);
    }

    function test_executeBatchRevertsAtomicallyOnAnyFailedCall() public {
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](2);
        calls[0] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});
        // Second call reverts: the whole batch must roll back.
        calls[1] = BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.boom, ())});

        PackedUserOperation memory op = _emptyOp(address(account));
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = abi.encodeCall(BaseAccount.executeBatch, (calls));
        op = _sign(ownerKey, op);

        // The inner batch reverts; the op is included but its execution rolls
        // back, so the counter is untouched (no partial application).
        _handle(op);
        assertEq(counter.count(), 0);
    }

    // ---------------------------------------------------------------- replay

    function test_reusedNonceReverts() public {
        PackedUserOperation memory op = _emptyOp(address(account));
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = _incrementCallData();
        op = _sign(ownerKey, op);

        _handle(op);
        assertEq(counter.count(), 1);

        // Same op again: the nonce was consumed, so the EntryPoint rejects it
        // before validation (AA25 invalid account nonce).
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA25 invalid account nonce"));
        entryPoint.handleOps(ops, payable(bundler));
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev A random batch of increments either all apply or none do; the
    ///      count moves by exactly the batch size when every call succeeds.
    function testFuzz_batchAppliesAtomically(uint8 n) public {
        uint256 size = bound(n, 1, 12);
        BaseAccount.Call[] memory calls = new BaseAccount.Call[](size);
        for (uint256 i = 0; i < size; i++) {
            calls[i] =
                BaseAccount.Call({target: address(counter), value: 0, data: abi.encodeCall(Counter.increment, ())});
        }

        PackedUserOperation memory op = _emptyOp(address(account));
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = abi.encodeCall(BaseAccount.executeBatch, (calls));
        op = _sign(ownerKey, op);

        _handle(op);
        assertEq(counter.count(), size);
        assertEq(counter.countBy(address(account)), size);
    }
}
