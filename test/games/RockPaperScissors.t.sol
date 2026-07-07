// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RockPaperScissors} from "../../src/games/RockPaperScissors.sol";

contract RockPaperScissorsTest is Test {
    RockPaperScissors internal rps;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant STAKE = 1 ether;
    bytes32 internal constant ALICE_SALT = keccak256("alice's strong random salt");
    bytes32 internal constant BOB_SALT = keccak256("bob's strong random salt");

    function setUp() public {
        rps = new RockPaperScissors();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function createAndJoin(RockPaperScissors.Move aliceMove, RockPaperScissors.Move bobMove)
        internal
        returns (uint256 id)
    {
        vm.prank(alice);
        id = rps.createGame{value: STAKE}(commitHash(aliceMove, ALICE_SALT, alice));
        vm.prank(bob);
        rps.joinGame{value: STAKE}(id, commitHash(bobMove, BOB_SALT, bob));
    }

    function playOut(RockPaperScissors.Move aliceMove, RockPaperScissors.Move bobMove)
        internal
        returns (uint256 id)
    {
        id = createAndJoin(aliceMove, bobMove);
        vm.prank(alice);
        rps.reveal(id, aliceMove, ALICE_SALT);
        vm.prank(bob);
        rps.reveal(id, bobMove, BOB_SALT);
        rps.settle(id);
    }

    // ─── Happy path ─────────────────────────────────────────────────────────

    function test_RockBeatsScissors_WinnerWithdrawsPot() public {
        playOut(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Scissors);

        assertEq(rps.balances(alice), 2 * STAKE);
        assertEq(rps.balances(bob), 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        rps.withdraw();
        assertEq(alice.balance, before + 2 * STAKE);
        assertEq(address(rps).balance, 0);
    }

    function test_DrawSplitsStakes() public {
        playOut(RockPaperScissors.Move.Paper, RockPaperScissors.Move.Paper);

        assertEq(rps.balances(alice), STAKE);
        assertEq(rps.balances(bob), STAKE);
    }

    function testFuzz_AllMoveCombinationsSettleCorrectly(uint8 rawA, uint8 rawB) public {
        RockPaperScissors.Move a = RockPaperScissors.Move(bound(rawA, 1, 3));
        RockPaperScissors.Move b = RockPaperScissors.Move(bound(rawB, 1, 3));

        playOut(a, b);

        // Expected winner by the classic rules, computed independently.
        uint8 ua = uint8(a);
        uint8 ub = uint8(b);
        if (ua == ub) {
            assertEq(rps.balances(alice), STAKE);
            assertEq(rps.balances(bob), STAKE);
        } else if ((ua == 1 && ub == 3) || (ua == 2 && ub == 1) || (ua == 3 && ub == 2)) {
            assertEq(rps.balances(alice), 2 * STAKE);
            assertEq(rps.balances(bob), 0);
        } else {
            assertEq(rps.balances(alice), 0);
            assertEq(rps.balances(bob), 2 * STAKE);
        }
    }

    // ─── Commitment integrity ───────────────────────────────────────────────

    function test_RevertWhen_RevealWithWrongSalt() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);

        vm.expectRevert(RockPaperScissors.CommitmentMismatch.selector);
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Rock, keccak256("wrong salt"));
    }

    function test_RevertWhen_RevealWithDifferentMove() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);

        // Alice committed Rock; seeing Bob's Paper coming, she tries Scissors.
        vm.expectRevert(RockPaperScissors.CommitmentMismatch.selector);
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Scissors, ALICE_SALT);
    }

    function test_CopiedCommitmentIsUseless() public {
        // Bob joins by copying Alice's exact commitment bytes.
        vm.prank(alice);
        uint256 id =
            rps.createGame{value: STAKE}(commitHash(RockPaperScissors.Move.Rock, ALICE_SALT, alice));
        vm.prank(bob);
        rps.joinGame{value: STAKE}(id, commitHash(RockPaperScissors.Move.Rock, ALICE_SALT, alice));

        // Even knowing Alice's move AND salt (say she revealed first), the
        // copied commitment never verifies for Bob: it binds Alice's address.
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);

        vm.expectRevert(RockPaperScissors.CommitmentMismatch.selector);
        vm.prank(bob);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);
    }

    function test_RevertWhen_RevealBeforeOpponentJoins() public {
        vm.prank(alice);
        uint256 id =
            rps.createGame{value: STAKE}(commitHash(RockPaperScissors.Move.Rock, ALICE_SALT, alice));

        vm.expectRevert(RockPaperScissors.RevealPhaseNotStarted.selector);
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);
    }

    function test_RevertWhen_StrangerReveals() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);

        vm.expectRevert(RockPaperScissors.NotAPlayer.selector);
        vm.prank(carol);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);
    }

    function test_RevertWhen_DoubleReveal() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);

        vm.expectRevert(RockPaperScissors.AlreadyRevealed.selector);
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);
    }

    // ─── Join constraints ───────────────────────────────────────────────────

    function test_RevertWhen_JoinWithWrongStake() public {
        vm.prank(alice);
        uint256 id =
            rps.createGame{value: STAKE}(commitHash(RockPaperScissors.Move.Rock, ALICE_SALT, alice));

        vm.expectRevert(RockPaperScissors.StakeMismatch.selector);
        vm.prank(bob);
        rps.joinGame{value: STAKE / 2}(id, commitHash(RockPaperScissors.Move.Paper, BOB_SALT, bob));
    }

    function test_RevertWhen_JoiningFullGame() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);

        vm.expectRevert(RockPaperScissors.GameFull.selector);
        vm.prank(carol);
        rps.joinGame{value: STAKE}(id, commitHash(RockPaperScissors.Move.Rock, BOB_SALT, carol));
    }

    function test_RevertWhen_CreatorJoinsOwnGame() public {
        vm.prank(alice);
        uint256 id =
            rps.createGame{value: STAKE}(commitHash(RockPaperScissors.Move.Rock, ALICE_SALT, alice));

        vm.expectRevert(RockPaperScissors.GameNotOpen.selector);
        vm.prank(alice);
        rps.joinGame{value: STAKE}(id, commitHash(RockPaperScissors.Move.Paper, ALICE_SALT, alice));
    }

    // ─── Settlement constraints ─────────────────────────────────────────────

    function test_RevertWhen_SettleBeforeBothRevealed() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);

        vm.expectRevert(RockPaperScissors.BothMovesNotRevealed.selector);
        rps.settle(id);
    }

    function test_RevertWhen_SettledGameTouchedAgain() public {
        uint256 id = playOut(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Scissors);

        vm.expectRevert(RockPaperScissors.GameClosed.selector);
        rps.settle(id);
    }

    function test_ClosedGameStaysReadable() public {
        uint256 id = playOut(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Scissors);

        // History must survive settlement: getGame on a closed game works.
        RockPaperScissors.Game memory game = rps.getGame(id);
        assertTrue(game.closed);
        assertEq(game.player1, alice);
        assertEq(game.player2, bob);
        assertEq(uint8(game.move1), uint8(RockPaperScissors.Move.Rock));
        assertEq(uint8(game.move2), uint8(RockPaperScissors.Move.Scissors));
    }

    // ─── Timeouts ───────────────────────────────────────────────────────────

    function test_SoleRevealerClaimsPotAfterTimeout() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);
        // Bob sees he would lose... wait, Paper beats Rock — Bob simply
        // griefs by never revealing. He forfeits.
        vm.warp(block.timestamp + rps.REVEAL_WINDOW() + 1);

        vm.prank(alice);
        rps.claimTimeout(id);

        assertEq(rps.balances(alice), 2 * STAKE);
        assertEq(rps.balances(bob), 0);
    }

    function test_NeitherRevealed_MutualRefundAfterTimeout() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);
        vm.warp(block.timestamp + rps.REVEAL_WINDOW() + 1);

        vm.prank(bob);
        rps.claimTimeout(id);

        assertEq(rps.balances(alice), STAKE);
        assertEq(rps.balances(bob), STAKE);
    }

    function test_RevertWhen_TimeoutClaimedEarly() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);

        vm.expectRevert(RockPaperScissors.RevealWindowNotOver.selector);
        vm.prank(alice);
        rps.claimTimeout(id);
    }

    function test_RevertWhen_RevealAfterWindow() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);
        vm.warp(block.timestamp + rps.REVEAL_WINDOW() + 1);

        vm.expectRevert(RockPaperScissors.RevealWindowOver.selector);
        vm.prank(alice);
        rps.reveal(id, RockPaperScissors.Move.Rock, ALICE_SALT);
    }

    // ─── Cancellation ───────────────────────────────────────────────────────

    function test_CancelUnjoinedGameRefundsStake() public {
        vm.prank(alice);
        uint256 id =
            rps.createGame{value: STAKE}(commitHash(RockPaperScissors.Move.Rock, ALICE_SALT, alice));

        vm.prank(alice);
        rps.cancelGame(id);

        assertEq(rps.balances(alice), STAKE);
    }

    function test_RevertWhen_CancellingJoinedGame() public {
        uint256 id = createAndJoin(RockPaperScissors.Move.Rock, RockPaperScissors.Move.Paper);

        vm.expectRevert(RockPaperScissors.GameFull.selector);
        vm.prank(alice);
        rps.cancelGame(id);
    }

    // ─── Withdraw safety ────────────────────────────────────────────────────

    function test_RevertWhen_WithdrawingNothing() public {
        vm.expectRevert(RockPaperScissors.NothingToClaim.selector);
        vm.prank(carol);
        rps.withdraw();
    }

    function test_ReentrantWithdrawGainsNothing() public {
        ReentrantWinner attacker = new ReentrantWinner(rps);
        vm.deal(address(attacker), STAKE);

        // Attacker wins a game legitimately, then tries to double-withdraw.
        attacker.create(STAKE, RockPaperScissors.Move.Rock);
        vm.prank(bob);
        rps.joinGame{value: STAKE}(0, commitHash(RockPaperScissors.Move.Scissors, BOB_SALT, bob));
        attacker.revealMove(0);
        vm.prank(bob);
        rps.reveal(0, RockPaperScissors.Move.Scissors, BOB_SALT);
        rps.settle(0);
        assertEq(rps.balances(address(attacker)), 2 * STAKE);

        // CEI: the reentrant inner withdraw sees a zeroed balance and reverts,
        // which bubbles up as TransferFailed for the outer call.
        vm.expectRevert(RockPaperScissors.TransferFailed.selector);
        attacker.attack();

        // Nothing moved; a normal (non-reentrant) withdraw still works.
        assertEq(rps.balances(address(attacker)), 2 * STAKE);
        attacker.withdrawNormally();
        assertEq(address(attacker).balance, 2 * STAKE);
    }
}

/// @dev Receiver that re-enters withdraw() from its receive hook when armed.
contract ReentrantWinner {
    RockPaperScissors private immutable rps;
    bytes32 private constant SALT = keccak256("attacker salt");
    bool private arm;

    constructor(RockPaperScissors rps_) {
        rps = rps_;
    }

    function create(uint256 stake, RockPaperScissors.Move move) external {
        rps.createGame{value: stake}(commitHash(move, SALT, address(this)));
    }

    function revealMove(uint256 id) external {
        rps.reveal(id, RockPaperScissors.Move.Rock, SALT);
    }

    function attack() external {
        arm = true;
        rps.withdraw();
        arm = false;
    }

    function withdrawNormally() external {
        rps.withdraw();
    }

    receive() external payable {
        if (arm) {
            rps.withdraw(); // reverts NothingToClaim: balance already zeroed
        }
    }
}

/// @dev Free-function mirror of RockPaperScissors.hashMove. Tests use this
///      instead of the contract's helper because an external view call in an
///      argument position consumes vm.prank/vm.expectRevert before the call
///      under test executes.
function commitHash(RockPaperScissors.Move move, bytes32 salt, address player)
    pure
    returns (bytes32)
{
    return keccak256(abi.encode(move, salt, player));
}
