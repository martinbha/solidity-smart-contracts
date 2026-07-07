// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RockPaperScissors
/// @notice Staked rock-paper-scissors using commit-reveal, because everything
///         on-chain is public — including pending transactions. A naive
///         "submit your move" design is broken by construction: the opponent
///         reads your move from the mempool and counters it. Instead, both
///         players first lock in keccak256(move, salt, player), and only
///         reveal once both commitments are down.
///
///         Griefing is handled with a reveal window: a player who sees they
///         lost and refuses to reveal simply forfeits — the sole revealer
///         claims the pot after the deadline.
///
///         Payouts are pull-based (credit balances, players withdraw) so a
///         reverting receiver can never block settlement.
contract RockPaperScissors {
    enum Move {
        None, // sentinel: "not revealed yet"
        Rock,
        Paper,
        Scissors
    }

    struct Game {
        // Slot 1: player1 (20B) + the four small fields (8B) pack together,
        // making the struct 5 slots instead of 6 — one less cold SSTORE per game.
        address player1;
        Move move1;
        Move move2;
        uint40 revealDeadline; // set when player2 joins; 0 = not started
        bool closed; // settled, timed out, or cancelled
        // Slots 2-5
        address player2;
        uint256 stake; // per player; pot is 2x
        bytes32 commitment1;
        bytes32 commitment2;
    }

    /// @notice Time both players have to reveal once the game is full.
    uint40 public constant REVEAL_WINDOW = 1 days;

    Game[] private _games;

    /// @notice Pull-payment ledger: winnings/refunds accrue here.
    mapping(address => uint256) public balances;

    event GameCreated(uint256 indexed id, address indexed player1, uint256 stake);
    event GameJoined(uint256 indexed id, address indexed player2, uint256 revealDeadline);
    event MoveRevealed(uint256 indexed id, address indexed player, Move move);
    event GameSettled(uint256 indexed id, address winner, uint256 pot); // winner=0 on draw
    event TimeoutClaimed(uint256 indexed id, address indexed claimer, uint256 amount);
    event GameCancelled(uint256 indexed id);
    event Withdrawal(address indexed account, uint256 amount);

    error InvalidMove();
    error StakeMismatch();
    error NotAPlayer();
    error GameNotOpen();
    error GameFull();
    error GameClosed();
    error RevealPhaseNotStarted();
    error RevealWindowOver();
    error RevealWindowNotOver();
    error CommitmentMismatch();
    error AlreadyRevealed();
    error BothMovesNotRevealed();
    error NothingToClaim();
    error TransferFailed();

    // ─── Game lifecycle ─────────────────────────────────────────────────────

    /// @notice Open a game with your stake and commitment. Compute the
    ///         commitment off-chain (or via hashMove) as
    ///         keccak256(abi.encode(move, salt, yourAddress)) with a strong
    ///         random salt — with only 3 possible moves, an unsalted or
    ///         weakly-salted commitment is brute-forceable instantly.
    function createGame(bytes32 commitment) external payable returns (uint256 id) {
        id = _games.length;
        Game storage game = _games.push();
        game.player1 = msg.sender;
        game.stake = msg.value;
        game.commitment1 = commitment;
        emit GameCreated(id, msg.sender, msg.value);
    }

    /// @notice Join an open game by matching the stake and committing. The
    ///         reveal window opens now: both commitments are locked.
    function joinGame(uint256 id, bytes32 commitment) external payable {
        Game storage game = _openGame(id);
        if (game.player2 != address(0)) revert GameFull();
        if (game.player1 == msg.sender) revert GameNotOpen();
        if (msg.value != game.stake) revert StakeMismatch();

        game.player2 = msg.sender;
        game.commitment2 = commitment;
        game.revealDeadline = uint40(block.timestamp) + REVEAL_WINDOW;
        emit GameJoined(id, msg.sender, game.revealDeadline);
    }

    /// @notice Reveal your move. Only meaningful once both players committed;
    ///         revealing must reproduce your commitment exactly.
    function reveal(uint256 id, Move move, bytes32 salt) external {
        Game storage game = _openGame(id);
        if (game.revealDeadline == 0) revert RevealPhaseNotStarted();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > game.revealDeadline) revert RevealWindowOver();
        if (move == Move.None || move > Move.Scissors) revert InvalidMove();

        if (msg.sender == game.player1) {
            if (game.move1 != Move.None) revert AlreadyRevealed();
            if (hashMove(move, salt, msg.sender) != game.commitment1) revert CommitmentMismatch();
            game.move1 = move;
        } else if (msg.sender == game.player2) {
            if (game.move2 != Move.None) revert AlreadyRevealed();
            if (hashMove(move, salt, msg.sender) != game.commitment2) revert CommitmentMismatch();
            game.move2 = move;
        } else {
            revert NotAPlayer();
        }
        emit MoveRevealed(id, msg.sender, move);
    }

    /// @notice Settle a fully revealed game: winner is credited the pot, a
    ///         draw splits it. Callable by anyone — settlement is mechanical.
    function settle(uint256 id) external {
        Game storage game = _openGame(id);
        if (game.move1 == Move.None || game.move2 == Move.None) revert BothMovesNotRevealed();

        game.closed = true;
        uint256 pot = game.stake * 2;
        address winner = _winner(game);
        if (winner == address(0)) {
            balances[game.player1] += game.stake;
            balances[game.player2] += game.stake;
        } else {
            balances[winner] += pot;
        }
        emit GameSettled(id, winner, pot);
    }

    /// @notice After the reveal window: a player who revealed claims the pot
    ///         if the opponent never did (refusing to reveal = forfeiting).
    ///         If neither revealed, each player just reclaims their own stake.
    function claimTimeout(uint256 id) external {
        Game storage game = _openGame(id);
        if (game.revealDeadline == 0) revert RevealPhaseNotStarted();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= game.revealDeadline) revert RevealWindowNotOver();
        if (msg.sender != game.player1 && msg.sender != game.player2) revert NotAPlayer();

        bool revealed1 = game.move1 != Move.None;
        bool revealed2 = game.move2 != Move.None;
        if (revealed1 && revealed2) revert NothingToClaim(); // settle() instead

        if (revealed1 != revealed2) {
            // Exactly one revealed: they take the pot.
            address claimer = revealed1 ? game.player1 : game.player2;
            game.closed = true;
            balances[claimer] += game.stake * 2;
            emit TimeoutClaimed(id, claimer, game.stake * 2);
        } else {
            // Neither revealed: mutual refund.
            game.closed = true;
            balances[game.player1] += game.stake;
            balances[game.player2] += game.stake;
            emit TimeoutClaimed(id, msg.sender, game.stake);
        }
    }

    /// @notice Cancel a game nobody joined and reclaim the stake.
    function cancelGame(uint256 id) external {
        Game storage game = _openGame(id);
        if (msg.sender != game.player1) revert NotAPlayer();
        if (game.player2 != address(0)) revert GameFull();

        game.closed = true;
        balances[game.player1] += game.stake;
        emit GameCancelled(id);
    }

    /// @notice Pull payments: transfer out everything credited to the caller.
    ///         Checks-effects-interactions — balance zeroed before the call.
    function withdraw() external {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert NothingToClaim();
        balances[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawal(msg.sender, amount);
    }

    // ─── Views ──────────────────────────────────────────────────────────────

    /// @notice The exact commitment reveal() will check. Binding the player
    ///         address means copying an opponent's commitment is useless: it
    ///         can never verify for the copier.
    function hashMove(Move move, bytes32 salt, address player) public pure returns (bytes32) {
        return keccak256(abi.encode(move, salt, player));
    }

    /// @notice Readable for every game ever played, closed or not — history
    ///         must not disappear once a game settles.
    function getGame(uint256 id) external view returns (Game memory) {
        return _games[id];
    }

    function gamesCount() external view returns (uint256) {
        return _games.length;
    }

    // ─── Internals ──────────────────────────────────────────────────────────

    /// @dev For mutating paths only: closed games reject all interaction.
    ///      Views read _games directly so history stays accessible.
    function _openGame(uint256 id) private view returns (Game storage game) {
        game = _games[id];
        if (game.closed) revert GameClosed();
    }

    /// @dev address(0) signals a draw. With Rock=1, Paper=2, Scissors=3:
    ///      (3 + m1 - m2) % 3 == 1 exactly when move1 beats move2.
    function _winner(Game storage game) private view returns (address) {
        uint256 m1 = uint256(game.move1);
        uint256 m2 = uint256(game.move2);
        if (m1 == m2) return address(0);
        return (3 + m1 - m2) % 3 == 1 ? game.player1 : game.player2;
    }
}
