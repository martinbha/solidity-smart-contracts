// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StreamManager
/// @notice Sablier-style payment streaming: a sender escrows ERC20 tokens and
///         the recipient's balance grows every second between `start` and
///         `end`, withdrawable at any moment once the `cliff` has passed.
///         Either side can cancel: the recipient keeps everything accrued so
///         far, the sender reclaims the rest, and the two payouts always sum
///         exactly to the original deposit.
///
/// @dev Precision strategy: accrual is always recomputed from the anchor as
///      `totalAmount * elapsed / duration` rather than accumulating a stored
///      per-second rate. A per-second rate loses `totalAmount % duration` wei
///      to integer division on every stream (dust that would strand in the
///      contract forever); recomputing from the total means the division
///      rounds down mid-stream but becomes exact at `end`, so the full
///      deposit is eventually withdrawable and the conservation invariant
///      `withdrawn + refund == totalAmount` holds without any dust sweep.
///
///      Reentrancy: all functions follow checks-effects-interactions —
///      `withdrawn` / `cancelled` are updated before any token transfer, so a
///      token with transfer hooks that reenters sees the already-settled
///      state and can extract nothing extra.
///
///      Token trust assumptions: escrow for a given token is pooled across
///      all of that token's streams, and the accounting trusts `totalAmount`
///      once the deposit lands. Fee-on-transfer tokens are rejected at
///      deposit (see createStream), but a token whose balances change *after*
///      deposit — rebasing down, admin burns, transfer hooks that skim —
///      leaves the pool short, and the shortfall silently lands on whichever
///      stream settles last. Only standard, balance-stable ERC20s are safe
///      to stream.
contract StreamManager {
    using SafeERC20 for IERC20;

    /// @dev Packed into four slots: sender+start+cliff+cancelled (31 bytes),
    ///      recipient+end (25), token (20), totalAmount+withdrawn (32).
    ///      uint128 covers any realistic token amount; uint40 covers
    ///      timestamps until year ~36800.
    struct Stream {
        address sender;
        uint40 start;
        uint40 cliff;
        bool cancelled;
        address recipient;
        uint40 end;
        address token;
        uint128 totalAmount;
        uint128 withdrawn;
    }

    /// @notice Stream storage by id. Ids start at 1 so 0 is never valid.
    mapping(uint256 => Stream) private _streams;

    /// @notice Id that will be assigned to the next stream created.
    uint256 public nextStreamId = 1;

    error ZeroAddress();
    error ZeroAmount();
    error AmountTooLarge(uint256 amount);
    error StartInPast(uint256 start);
    error InvalidTimeRange(uint256 start, uint256 cliff, uint256 end);
    error TimestampTooLarge(uint256 timestamp);
    error FeeOnTransferToken(uint256 expected, uint256 received);
    error StreamNotFound(uint256 id);
    error NotRecipient(uint256 id, address caller);
    error NotStreamParty(uint256 id, address caller);
    error AlreadyCancelled(uint256 id);
    error ExceedsWithdrawable(uint256 id, uint256 requested, uint256 available);

    event StreamCreated(
        uint256 indexed id,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 totalAmount,
        uint40 start,
        uint40 cliff,
        uint40 end
    );
    event Withdrawn(uint256 indexed id, address indexed recipient, uint256 amount);
    event StreamCancelled(uint256 indexed id, address indexed caller, uint256 recipientPayout, uint256 senderRefund);

    /// @notice Escrow `totalAmount` of `token` and open a stream to
    ///         `recipient` that accrues linearly from `start` to `end`.
    ///         Nothing is withdrawable before `cliff`; once the cliff passes,
    ///         everything accrued since `start` unlocks at once.
    /// @dev Rejects fee-on-transfer tokens by measuring the actual balance
    ///      delta: if the contract received less than `totalAmount`, the
    ///      accounting above (which trusts `totalAmount`) would let the last
    ///      withdrawer or canceller pull other streams' escrow, so we refuse
    ///      the deposit outright rather than silently re-basing it.
    function createStream(
        address recipient,
        address token,
        uint256 totalAmount,
        uint256 start,
        uint256 cliff,
        uint256 end
    ) external returns (uint256 id) {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (totalAmount > type(uint128).max) revert AmountTooLarge(totalAmount);
        // forge-lint: disable-next-line(block-timestamp)
        if (start < block.timestamp) revert StartInPast(start);
        if (end > type(uint40).max) revert TimestampTooLarge(end);
        if (start > cliff || cliff > end || start == end) {
            revert InvalidTimeRange(start, cliff, end);
        }

        // Casts cannot truncate: the checks above bound totalAmount by
        // uint128.max and start <= cliff <= end <= uint40.max.
        // forge-lint: disable-start(unsafe-typecast)
        uint128 amount128 = uint128(totalAmount);
        uint40 start40 = uint40(start);
        uint40 cliff40 = uint40(cliff);
        uint40 end40 = uint40(end);
        // forge-lint: disable-end(unsafe-typecast)

        id = nextStreamId++;
        _streams[id] = Stream({
            sender: msg.sender,
            start: start40,
            cliff: cliff40,
            cancelled: false,
            recipient: recipient,
            end: end40,
            token: token,
            totalAmount: amount128,
            withdrawn: 0
        });

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != totalAmount) revert FeeOnTransferToken(totalAmount, received);

        emit StreamCreated(id, msg.sender, recipient, token, totalAmount, start40, cliff40, end40);
    }

    /// @notice Amount the recipient could withdraw right now: zero before the
    ///         cliff, the accrued-minus-withdrawn amount while streaming, and
    ///         the full remainder after `end`. Zero once cancelled (the
    ///         cancellation already paid out everything accrued).
    function balanceOf(uint256 id) external view returns (uint256) {
        return _withdrawable(_getStream(id));
    }

    /// @notice Withdraw `amount` streamed tokens. Recipient only. Pass
    ///         `type(uint256).max` to withdraw everything available.
    function withdraw(uint256 id, uint256 amount) external {
        Stream storage stream = _getStream(id);
        if (msg.sender != stream.recipient) revert NotRecipient(id, msg.sender);

        uint256 available = _withdrawable(stream);
        if (amount == type(uint256).max) amount = available;
        if (amount == 0) revert ZeroAmount();
        if (amount > available) revert ExceedsWithdrawable(id, amount, available);

        // Cast cannot truncate: amount <= available <= totalAmount (uint128).
        // forge-lint: disable-next-line(unsafe-typecast)
        stream.withdrawn += uint128(amount);
        emit Withdrawn(id, stream.recipient, amount);
        IERC20(stream.token).safeTransfer(stream.recipient, amount);
    }

    /// @notice Cancel the stream. Callable by sender or recipient. The
    ///         recipient is paid everything accrued and not yet withdrawn;
    ///         the sender is refunded the rest, atomically, so the total paid
    ///         out over the stream's life is exactly `totalAmount`.
    /// @dev Cancelling after `end` still works: it simply pays the recipient
    ///      the full remainder and refunds the sender nothing.
    ///
    ///      Both payouts are pushed in one transaction (per the atomicity
    ///      requirement in issue #8). The trade-off: a token that can block
    ///      transfers to an address (e.g. a blacklist) lets one frozen party
    ///      make cancel revert, locking the other party's share in escrow
    ///      too. Production streaming protocols avoid this by making cancel
    ///      pull-based — refund the sender, leave the recipient's accrued
    ///      share claimable via withdraw.
    function cancel(uint256 id) external {
        Stream storage stream = _getStream(id);
        if (msg.sender != stream.sender && msg.sender != stream.recipient) {
            revert NotStreamParty(id, msg.sender);
        }
        if (stream.cancelled) revert AlreadyCancelled(id);

        // The recipient's share ignores the cliff: cancellation settles what
        // has genuinely accrued, even if it was not yet withdrawable. A cliff
        // gates early *withdrawal*, not ownership of streamed funds.
        uint256 accrued = _accrued(stream);
        uint256 recipientPayout = accrued - stream.withdrawn;
        uint256 senderRefund = stream.totalAmount - accrued;

        stream.cancelled = true;
        // Cast cannot truncate: accrued <= totalAmount (uint128).
        // forge-lint: disable-next-line(unsafe-typecast)
        stream.withdrawn = uint128(accrued);

        emit StreamCancelled(id, msg.sender, recipientPayout, senderRefund);

        IERC20 token = IERC20(stream.token);
        if (recipientPayout > 0) token.safeTransfer(stream.recipient, recipientPayout);
        if (senderRefund > 0) token.safeTransfer(stream.sender, senderRefund);
    }

    /// @notice Full stream state for off-chain inspection.
    function getStream(uint256 id) external view returns (Stream memory) {
        return _getStream(id);
    }

    /// @dev Fetch a stream or revert; `sender` doubles as the existence flag
    ///      since createStream never stores the zero address.
    function _getStream(uint256 id) private view returns (Stream storage stream) {
        stream = _streams[id];
        if (stream.sender == address(0)) revert StreamNotFound(id);
    }

    /// @dev Withdrawable right now: zero before the cliff or once cancelled,
    ///      accrued-minus-withdrawn otherwise.
    function _withdrawable(Stream storage stream) private view returns (uint256) {
        // forge-lint: disable-next-line(block-timestamp)
        if (stream.cancelled || block.timestamp < stream.cliff) return 0;
        return _accrued(stream) - stream.withdrawn;
    }

    /// @dev Total streamed since `start`, clamped to [0, totalAmount].
    ///      Computed fresh from the anchor each call — see the precision note
    ///      on the contract — so at `block.timestamp >= end` the division
    ///      disappears and the exact `totalAmount` is returned.
    function _accrued(Stream storage stream) private view returns (uint256) {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= stream.start) return 0;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= stream.end) return stream.totalAmount;
        uint256 elapsed = block.timestamp - stream.start;
        uint256 duration = stream.end - stream.start;
        return (uint256(stream.totalAmount) * elapsed) / duration;
    }
}
