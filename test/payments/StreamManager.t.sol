// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StreamToken} from "../../src/payments/StreamToken.sol";
import {StreamManager} from "../../src/payments/StreamManager.sol";

/// @dev ERC20 that skims a 1% fee on every transfer, to prove the manager
///      rejects tokens whose received amount differs from the sent amount.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = value / 100;
        if (from != address(0) && to != address(0) && fee > 0) {
            super._update(from, to, value - fee);
            super._update(from, address(0xFEE), fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract StreamManagerTest is Test {
    StreamToken internal token;
    StreamManager internal manager;

    address internal sender = makeAddr("sender");
    address internal recipient = makeAddr("recipient");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant TOTAL = 30_000 ether;
    uint40 internal start;
    uint40 internal cliff;
    uint40 internal end;

    function setUp() public {
        token = new StreamToken();
        manager = new StreamManager();

        // Anchor away from t=0 so "start in the past" cases have room.
        vm.warp(30 days);
        start = uint40(block.timestamp + 1 days);
        cliff = start + 7 days;
        end = start + 30 days;

        token.mint(sender, TOTAL * 10);
        vm.prank(sender);
        token.approve(address(manager), type(uint256).max);
    }

    function _createDefaultStream() internal returns (uint256 id) {
        vm.prank(sender);
        id = manager.createStream(recipient, address(token), TOTAL, start, cliff, end);
    }

    // ------------------------------------------------------------- creation

    function test_CreateStreamEscrowsDepositAndStoresStream() public {
        uint256 id = _createDefaultStream();

        assertEq(id, 1);
        assertEq(token.balanceOf(address(manager)), TOTAL);

        StreamManager.Stream memory s = manager.getStream(id);
        assertEq(s.sender, sender);
        assertEq(s.recipient, recipient);
        assertEq(s.token, address(token));
        assertEq(s.totalAmount, TOTAL);
        assertEq(s.start, start);
        assertEq(s.cliff, cliff);
        assertEq(s.end, end);
        assertEq(s.withdrawn, 0);
        assertFalse(s.cancelled);
    }

    function test_CreateStreamRevertsOnZeroRecipientOrToken() public {
        vm.expectRevert(StreamManager.ZeroAddress.selector);
        vm.prank(sender);
        manager.createStream(address(0), address(token), TOTAL, start, cliff, end);

        vm.expectRevert(StreamManager.ZeroAddress.selector);
        vm.prank(sender);
        manager.createStream(recipient, address(0), TOTAL, start, cliff, end);
    }

    function test_CreateStreamRevertsOnZeroAmount() public {
        vm.expectRevert(StreamManager.ZeroAmount.selector);
        vm.prank(sender);
        manager.createStream(recipient, address(token), 0, start, cliff, end);
    }

    function test_CreateStreamRevertsOnAmountOverUint128() public {
        uint256 huge = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(StreamManager.AmountTooLarge.selector, huge));
        vm.prank(sender);
        manager.createStream(recipient, address(token), huge, start, cliff, end);
    }

    function test_CreateStreamRevertsOnStartInPast() public {
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(StreamManager.StartInPast.selector, past));
        vm.prank(sender);
        manager.createStream(recipient, address(token), TOTAL, past, cliff, end);
    }

    function test_CreateStreamRevertsOnZeroDuration() public {
        vm.expectRevert(abi.encodeWithSelector(StreamManager.InvalidTimeRange.selector, start, start, start));
        vm.prank(sender);
        manager.createStream(recipient, address(token), TOTAL, start, start, start);
    }

    function test_CreateStreamRevertsOnCliffOutsideWindow() public {
        // cliff > end
        vm.expectRevert(abi.encodeWithSelector(StreamManager.InvalidTimeRange.selector, start, end + 1, end));
        vm.prank(sender);
        manager.createStream(recipient, address(token), TOTAL, start, end + 1, end);

        // cliff < start
        vm.expectRevert(abi.encodeWithSelector(StreamManager.InvalidTimeRange.selector, start, start - 1, end));
        vm.prank(sender);
        manager.createStream(recipient, address(token), TOTAL, start, start - 1, end);
    }

    function test_CreateStreamRevertsOnTimestampOverUint40() public {
        uint256 farEnd = uint256(type(uint40).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(StreamManager.TimestampTooLarge.selector, farEnd));
        vm.prank(sender);
        manager.createStream(recipient, address(token), TOTAL, start, cliff, farEnd);
    }

    function test_CreateStreamRejectsFeeOnTransferToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(sender, TOTAL);
        vm.startPrank(sender);
        feeToken.approve(address(manager), TOTAL);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.FeeOnTransferToken.selector, TOTAL, TOTAL - TOTAL / 100));
        manager.createStream(recipient, address(feeToken), TOTAL, start, cliff, end);
        vm.stopPrank();
    }

    function test_GetStreamRevertsOnUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(StreamManager.StreamNotFound.selector, 42));
        manager.getStream(42);
    }

    // ------------------------------------------------------------- accrual

    function test_NothingWithdrawableBeforeCliff() public {
        uint256 id = _createDefaultStream();

        vm.warp(start - 1);
        assertEq(manager.balanceOf(id), 0);

        vm.warp(cliff - 1);
        assertEq(manager.balanceOf(id), 0);

        vm.prank(recipient);
        vm.expectRevert(StreamManager.ZeroAmount.selector);
        manager.withdraw(id, type(uint256).max);
    }

    function test_ProportionalAccrualAfterCliff() public {
        uint256 id = _createDefaultStream();

        // At the cliff, everything accrued since start unlocks at once.
        vm.warp(cliff);
        assertEq(manager.balanceOf(id), TOTAL * (cliff - start) / (end - start));

        // Halfway through the stream, exactly half is withdrawable.
        vm.warp(start + (end - start) / 2);
        assertEq(manager.balanceOf(id), TOTAL / 2);
    }

    function test_FullAmountAfterEnd() public {
        uint256 id = _createDefaultStream();

        vm.warp(end);
        assertEq(manager.balanceOf(id), TOTAL);

        vm.warp(end + 365 days);
        assertEq(manager.balanceOf(id), TOTAL);
    }

    // ------------------------------------------------------------ withdraw

    function test_WithdrawTransfersToRecipientAndTracksTotal() public {
        uint256 id = _createDefaultStream();
        vm.warp(start + (end - start) / 2);

        vm.prank(recipient);
        manager.withdraw(id, 1_000 ether);
        assertEq(token.balanceOf(recipient), 1_000 ether);
        assertEq(manager.balanceOf(id), TOTAL / 2 - 1_000 ether);
        assertEq(manager.getStream(id).withdrawn, 1_000 ether);
    }

    function test_WithdrawMaxTakesEverythingAvailable() public {
        uint256 id = _createDefaultStream();
        vm.warp(start + (end - start) / 2);

        vm.prank(recipient);
        manager.withdraw(id, type(uint256).max);
        assertEq(token.balanceOf(recipient), TOTAL / 2);
        assertEq(manager.balanceOf(id), 0);
    }

    function test_PartialWithdrawalsNeverExceedAccrued() public {
        uint256 id = _createDefaultStream();
        uint256 duration = end - start;

        // Withdraw everything available at several points; each step can only
        // take what accrued since the previous one, never more.
        uint256 total;
        for (uint256 i = 1; i <= 4; i++) {
            vm.warp(cliff + (i * (end - cliff)) / 4);
            uint256 available = manager.balanceOf(id);
            uint256 accruedCap = TOTAL * (block.timestamp - start) / duration;
            assertLe(total + available, accruedCap);
            vm.prank(recipient);
            manager.withdraw(id, type(uint256).max);
            total += available;
        }
        assertEq(total, TOTAL);
        assertEq(token.balanceOf(recipient), TOTAL);
    }

    function test_WithdrawRevertsForNonRecipient() public {
        uint256 id = _createDefaultStream();
        vm.warp(end);

        vm.expectRevert(abi.encodeWithSelector(StreamManager.NotRecipient.selector, id, sender));
        vm.prank(sender);
        manager.withdraw(id, 1);

        vm.expectRevert(abi.encodeWithSelector(StreamManager.NotRecipient.selector, id, outsider));
        vm.prank(outsider);
        manager.withdraw(id, 1);
    }

    function test_WithdrawRevertsAboveAvailable() public {
        uint256 id = _createDefaultStream();
        vm.warp(start + (end - start) / 2);

        uint256 available = manager.balanceOf(id);
        vm.expectRevert(
            abi.encodeWithSelector(StreamManager.ExceedsWithdrawable.selector, id, available + 1, available)
        );
        vm.prank(recipient);
        manager.withdraw(id, available + 1);
    }

    function test_WithdrawRevertsOnUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(StreamManager.StreamNotFound.selector, 7));
        vm.prank(recipient);
        manager.withdraw(7, 1);
    }

    // -------------------------------------------------------------- cancel

    function test_CancelMidStreamSplitsDepositExactly() public {
        uint256 id = _createDefaultStream();

        // Withdraw a bit first so cancel has to account for prior withdrawals.
        vm.warp(cliff);
        vm.prank(recipient);
        manager.withdraw(id, type(uint256).max);
        uint256 withdrawnAtCliff = token.balanceOf(recipient);

        vm.warp(start + (end - start) / 2);
        vm.prank(sender);
        manager.cancel(id);

        uint256 accrued = TOTAL / 2;
        assertEq(token.balanceOf(recipient), accrued);
        assertEq(token.balanceOf(sender), TOTAL * 10 - TOTAL + (TOTAL - accrued));
        assertGt(token.balanceOf(recipient), withdrawnAtCliff);

        // Conservation: everything paid out, nothing stranded in the manager.
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(manager.balanceOf(id), 0);
    }

    function test_CancelBeforeCliffPaysAccruedDespiteCliff() public {
        uint256 id = _createDefaultStream();

        // Before the cliff nothing is *withdrawable*, but cancellation still
        // settles what has accrued since start.
        vm.warp(start + 2 days);
        assertEq(manager.balanceOf(id), 0);

        vm.prank(recipient);
        manager.cancel(id);

        uint256 accrued = TOTAL * 2 days / (end - start);
        assertEq(token.balanceOf(recipient), accrued);
        assertEq(token.balanceOf(address(manager)), 0);
    }

    function test_CancelBeforeStartRefundsEverything() public {
        uint256 id = _createDefaultStream();

        vm.prank(sender);
        manager.cancel(id);

        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(sender), TOTAL * 10);
        assertEq(token.balanceOf(address(manager)), 0);
    }

    function test_CancelAfterEndPaysRecipientEverything() public {
        uint256 id = _createDefaultStream();
        vm.warp(end + 1);

        vm.prank(recipient);
        manager.cancel(id);

        assertEq(token.balanceOf(recipient), TOTAL);
        assertEq(token.balanceOf(sender), TOTAL * 10 - TOTAL);
    }

    function test_CancelRevertsForOutsider() public {
        uint256 id = _createDefaultStream();
        vm.expectRevert(abi.encodeWithSelector(StreamManager.NotStreamParty.selector, id, outsider));
        vm.prank(outsider);
        manager.cancel(id);
    }

    function test_DoubleCancelReverts() public {
        uint256 id = _createDefaultStream();
        vm.prank(sender);
        manager.cancel(id);

        vm.expectRevert(abi.encodeWithSelector(StreamManager.AlreadyCancelled.selector, id));
        vm.prank(recipient);
        manager.cancel(id);
    }

    function test_WithdrawAfterCancelReverts() public {
        uint256 id = _createDefaultStream();
        vm.warp(start + (end - start) / 2);
        vm.prank(sender);
        manager.cancel(id);

        // Cancellation already paid the recipient everything accrued.
        vm.expectRevert(StreamManager.ZeroAmount.selector);
        vm.prank(recipient);
        manager.withdraw(id, type(uint256).max);
    }

    // ------------------------------------------------- multiple streams

    function test_OverlappingStreamsForSameRecipientDoNotInterfere() public {
        uint256 idA = _createDefaultStream();
        // Second stream: half the amount, twice the duration, no cliff gap.
        vm.prank(sender);
        uint256 idB = manager.createStream(recipient, address(token), TOTAL / 2, start, start, start + 60 days);

        vm.warp(start + (end - start) / 2); // A: 50% through; B: 25% through
        assertEq(manager.balanceOf(idA), TOTAL / 2);
        assertEq(manager.balanceOf(idB), TOTAL / 8);

        // Draining A leaves B untouched.
        vm.prank(recipient);
        manager.withdraw(idA, type(uint256).max);
        assertEq(manager.balanceOf(idA), 0);
        assertEq(manager.balanceOf(idB), TOTAL / 8);

        // Cancelling B leaves A's remaining accrual intact.
        vm.prank(sender);
        manager.cancel(idB);
        vm.warp(end);
        assertEq(manager.balanceOf(idA), TOTAL / 2);
        vm.prank(recipient);
        manager.withdraw(idA, type(uint256).max);
        assertEq(token.balanceOf(recipient), TOTAL + TOTAL / 8);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Conservation invariant: however the stream ends (arbitrary
    ///      mid-stream withdrawal then cancel at an arbitrary time),
    ///      recipient + sender payouts always sum exactly to the deposit.
    function testFuzz_WithdrawnPlusRefundEqualsTotal(
        uint128 totalAmount,
        uint40 durationSeed,
        uint40 cliffSeed,
        uint40 warpSeed,
        uint256 withdrawSeed
    ) public {
        uint256 amount = bound(uint256(totalAmount), 1, type(uint128).max);
        uint256 duration = bound(uint256(durationSeed), 1, 10 * 365 days);
        uint256 cliffOffset = bound(uint256(cliffSeed), 0, duration);
        uint256 s = block.timestamp + 1 days;

        token.mint(sender, amount);
        vm.prank(sender);
        uint256 id = manager.createStream(recipient, address(token), amount, s, s + cliffOffset, s + duration);

        uint256 senderBefore = token.balanceOf(sender);

        // Warp anywhere from before start to well past end and withdraw an
        // arbitrary slice of whatever is available.
        vm.warp(bound(uint256(warpSeed), s - 1 days, s + duration + 30 days));
        uint256 available = manager.balanceOf(id);
        if (available > 0) {
            uint256 amt = bound(withdrawSeed, 1, available);
            vm.prank(recipient);
            manager.withdraw(id, amt);
        }

        vm.prank(sender);
        manager.cancel(id);

        uint256 recipientDelta = token.balanceOf(recipient);
        uint256 senderDelta = token.balanceOf(sender) - senderBefore;
        assertEq(recipientDelta + senderDelta, amount, "conservation violated");
        assertEq(token.balanceOf(address(manager)), 0, "dust stranded");
    }

    /// @dev balanceOf never decreases while a stream is active (no
    ///      withdrawals or cancellation in between observations).
    function testFuzz_BalanceOfMonotonicallyNonDecreasing(
        uint128 totalAmount,
        uint40 durationSeed,
        uint40 cliffSeed,
        uint40 t1Seed,
        uint40 t2Seed
    ) public {
        uint256 amount = bound(uint256(totalAmount), 1, type(uint128).max);
        uint256 duration = bound(uint256(durationSeed), 1, 10 * 365 days);
        uint256 cliffOffset = bound(uint256(cliffSeed), 0, duration);
        uint256 s = block.timestamp + 1 days;

        token.mint(sender, amount);
        vm.prank(sender);
        uint256 id = manager.createStream(recipient, address(token), amount, s, s + cliffOffset, s + duration);

        uint256 t1 = bound(uint256(t1Seed), block.timestamp, s + duration + 30 days);
        uint256 t2 = bound(uint256(t2Seed), t1, s + duration + 30 days);

        vm.warp(t1);
        uint256 earlier = manager.balanceOf(id);
        vm.warp(t2);
        uint256 later = manager.balanceOf(id);
        assertGe(later, earlier, "balanceOf decreased over time");
    }
}
