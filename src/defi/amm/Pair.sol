// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Pair
/// @notice A single-pair constant-product pool: `x · y = k`. The pool holds
///         two ERC20s and every swap must leave their product no smaller than
///         it was. There is no order book and no quoted price — the curve *is*
///         the price, and the marginal rate is simply `reserveOut / reserveIn`.
///         Buy enough of one side and you walk up the curve, paying worse and
///         worse rates: that is price impact, and it falls out of the maths
///         rather than being programmed in.
///
/// @dev The pool is also its own LP token. Shares are ERC20, so the claim on
///      the reserves is transferable and composable.
///
///      Fees: swaps charge 30 basis points on the input and keep it in the
///      pool. Nothing is paid out; `k` simply grows, so every share is worth
///      slightly more reserves afterwards. LPs are paid by holding.
///
///      Share-inflation defence: the first depositor mints `sqrt(a·b)` shares
///      and `MINIMUM_LIQUIDITY` of them are burned to a dead address, never
///      redeemable. Without that lock a first depositor could mint one wei of
///      shares, donate a large balance directly to the pool, and make every
///      subsequent deposit round down to zero shares — the same rounding
///      attack ERC-4626 vaults defend against with virtual offsets.
///
///      Ratio discipline: `addLiquidity` mints against whichever side is
///      scarcer relative to the reserves. Deposit off-ratio and the excess is
///      donated to the pool rather than refunded — exactly Uniswap V2's
///      behaviour, where a router computes matching amounts before calling in.
///      Use `quote` to size the second leg.
///
///      Oracle: every reserve change accumulates `price · secondsElapsed` into
///      `price0CumulativeLast`. A reader anchors with `updateOracle` and later
///      calls `consult`, which divides the accumulated difference by the
///      elapsed time. Because each price is weighted by how long it survived,
///      a flash loan that slams the pool and restores it in the same block
///      contributes zero seconds and therefore moves the average not at all.
///
///      Token assumptions: standard, balance-stable ERC20s. Amounts credited
///      are measured from actual balance deltas, so a fee-on-transfer token
///      does not corrupt the accounting, but reserves must always fit in
///      `uint112` — a deliberate ceiling inherited from the packed-slot layout
///      the price accumulator depends on.
contract Pair is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Shares burned on the first deposit so total supply can never
    ///         return to zero. 1000 wei of shares, unredeemable forever.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @dev OpenZeppelin's ERC20 refuses to mint to `address(0)`, so the
    ///      locked shares go to a provably unspendable address instead.
    address public constant BURN_ADDRESS = address(0xdEaD);

    /// @dev 0.30% swap fee, expressed as the numerator kept after the cut.
    uint256 internal constant FEE_NUMERATOR = 997;
    uint256 internal constant FEE_DENOMINATOR = 1000;

    /// @dev The price accumulator holds UQ112x112 fixed-point values: a price
    ///      is a 224-bit number whose low 112 bits are the fraction.
    uint256 internal constant Q112 = 2 ** 112;

    /// @notice The factory that deployed this pair and initialized its tokens.
    address public immutable factory;

    /// @notice The pooled tokens, sorted so `token0 < token1`.
    address public token0;
    address public token1;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    /// @notice Running sum of `price(token0 in token1) · secondsElapsed`, in
    ///         UQ112x112. Allowed to overflow: only differences are read.
    uint256 public price0CumulativeLast;

    /// @dev One reader's snapshot of the accumulator.
    struct Observation {
        uint256 price0Cumulative;
        uint32 timestamp;
        bool set;
    }

    /// @notice Each consumer's own anchor. Windows are per-caller so nobody
    ///         can shorten anybody else's.
    mapping(address consumer => Observation observation) public anchors;

    error AlreadyInitialized();
    error NotFactory();
    error IdenticalTokens();
    error ZeroAddressToken();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientLiquidity();
    error InsufficientInputAmount();
    error InsufficientOutputAmount(uint256 amountOut, uint256 minAmountOut);
    error InvalidToken(address token);
    error InvariantViolated();
    error ReserveOverflow();
    error NoElapsedTime();
    error NoAnchor(address consumer);

    event Mint(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Burn(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Swap(
        address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event OracleAnchored(address indexed consumer, uint256 price0Cumulative, uint32 timestamp);

    constructor() ERC20("Constant Product LP", "CP-LP") {
        factory = msg.sender;
    }

    /// @notice Sets the pooled tokens. Called once by the factory immediately
    ///         after deployment.
    /// @dev Tokens are constructor-free so the CREATE2 init-code hash is a
    ///      constant, which is what makes pair addresses computable off-chain
    ///      before the pair exists.
    function initialize(address tokenA, address tokenB) external {
        if (msg.sender != factory) revert NotFactory();
        if (token0 != address(0)) revert AlreadyInitialized();
        if (tokenA == tokenB) revert IdenticalTokens();
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddressToken();

        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // ------------------------------------------------------------- reserves

    /// @notice Current reserves and the timestamp they were last updated at.
    function getReserves() public view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    /// @notice The constant-product invariant, `reserve0 · reserve1`.
    function k() external view returns (uint256) {
        return uint256(_reserve0) * uint256(_reserve1);
    }

    // ------------------------------------------------------------ liquidity

    /// @notice Deposits both sides and mints LP shares to the caller.
    /// @dev The first deposit sets the price; every later one must match the
    ///      current ratio or forfeit the excess to the pool.
    /// @param amount0 Amount of `token0` to pull from the caller.
    /// @param amount1 Amount of `token1` to pull from the caller.
    /// @return shares LP shares minted.
    function addLiquidity(uint256 amount0, uint256 amount1) external nonReentrant returns (uint256 shares) {
        (uint112 reserve0, uint112 reserve1,) = getReserves();

        uint256 received0 = _pull(token0, amount0);
        uint256 received1 = _pull(token1, amount1);

        uint256 supply = totalSupply();
        if (supply == 0) {
            // Subtracting the lock first would panic on a dust-sized first
            // deposit; check it so the caller gets a named error instead.
            uint256 seeded = Math.sqrt(received0 * received1);
            if (seeded <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            shares = seeded - MINIMUM_LIQUIDITY;
            _mint(BURN_ADDRESS, MINIMUM_LIQUIDITY);
        } else {
            // Whichever side is scarcer relative to the reserves decides the
            // mint; the other side's surplus stays in the pool for everyone.
            shares = Math.min(Math.mulDiv(received0, supply, reserve0), Math.mulDiv(received1, supply, reserve1));
        }
        if (shares == 0) revert InsufficientLiquidityMinted();

        _mint(msg.sender, shares);
        _update();

        emit Mint(msg.sender, msg.sender, received0, received1, shares);
    }

    /// @notice Burns LP shares and returns the caller's pro-rata reserves.
    /// @param shares LP shares to burn.
    /// @return amount0 `token0` returned.
    /// @return amount1 `token1` returned.
    function removeLiquidity(uint256 shares) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalSupply();
        if (supply == 0) revert InsufficientLiquidity();

        // Pro-rata against real balances, not cached reserves, so any tokens
        // donated directly to the pool are distributed rather than stranded.
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        amount0 = Math.mulDiv(shares, balance0, supply);
        amount1 = Math.mulDiv(shares, balance1, supply);
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(msg.sender, shares);
        IERC20(token0).safeTransfer(msg.sender, amount0);
        IERC20(token1).safeTransfer(msg.sender, amount1);
        _update();

        emit Burn(msg.sender, msg.sender, amount0, amount1, shares);
    }

    // ---------------------------------------------------------------- swaps

    /// @notice Swaps `amountIn` of `tokenIn` for as much of the other token as
    ///         the curve allows, reverting if that is below `minAmountOut`.
    /// @param tokenIn Which side of the pair is being sold.
    /// @param amountIn Amount pulled from the caller.
    /// @param minAmountOut Slippage guard: the smallest acceptable output.
    /// @return amountOut Amount of the other token sent to the caller.
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (tokenIn != token0 && tokenIn != token1) revert InvalidToken(tokenIn);

        (uint112 reserve0, uint112 reserve1,) = getReserves();
        bool zeroForOne = tokenIn == token0;
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // Price the swap against what actually arrived, never the requested
        // amount, so the reserves and the maths can never disagree.
        uint256 received = _pull(tokenIn, amountIn);
        if (received == 0) revert InsufficientInputAmount();

        amountOut = getAmountOut(received, reserveIn, reserveOut);
        if (amountOut == 0 || amountOut < minAmountOut) revert InsufficientOutputAmount(amountOut, minAmountOut);

        address tokenOut = zeroForOne ? token1 : token0;
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        _update();

        // Belt and braces: re-derive the invariant from post-swap balances so
        // an exotic token that moved more than expected cannot drain the pool.
        (uint112 newReserve0, uint112 newReserve1,) = getReserves();
        if (uint256(newReserve0) * uint256(newReserve1) < uint256(reserve0) * uint256(reserve1)) {
            revert InvariantViolated();
        }

        emit Swap(msg.sender, tokenIn, received, amountOut, msg.sender);
    }

    /// @notice The constant-product swap formula with the 0.30% fee applied to
    ///         the input.
    /// @dev Solving `(reserveIn + amountIn·997/1000) · (reserveOut - out) = k`
    ///      for `out`. Division truncates, which always rounds in the pool's
    ///      favour.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice The input required to receive exactly `amountOut`, fee included.
    /// @dev Rounds up, so the caller never underpays the pool by a wei.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientOutputAmount(0, 1);
        if (reserveOut <= amountOut) revert InsufficientLiquidity();

        uint256 numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * FEE_NUMERATOR;
        amountIn = numerator / denominator + 1;
    }

    /// @notice The amount of the other token that matches `amountA` at the
    ///         current ratio. Size the second leg of `addLiquidity` with this.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientInputAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = Math.mulDiv(amountA, reserveB, reserveA);
    }

    // --------------------------------------------------------------- oracle

    /// @notice Anchors the caller's own TWAP window at the current cumulative
    ///         price.
    /// @dev Anchors are per-caller on purpose. A single shared anchor would be
    ///      worthless: anyone could re-anchor in the block before a consumer
    ///      read the oracle, collapsing its window to a few seconds and
    ///      handing back something barely distinguishable from spot — exactly
    ///      the manipulation the TWAP exists to prevent. Owning your window is
    ///      what makes the average trustworthy, so each consumer keeps its own.
    function updateOracle() external {
        _accumulate();
        anchors[msg.sender] = Observation(price0CumulativeLast, _blockTimestampLast, true);
        emit OracleAnchored(msg.sender, price0CumulativeLast, _blockTimestampLast);
    }

    /// @notice Time-weighted average price of `token0` denominated in
    ///         `token1`, over the caller's window since its own
    ///         `updateOracle`, scaled by 1e18.
    /// @dev Includes the time elapsed since the last reserve change, so an
    ///      idle pool still reports a meaningful average. Reverts if no time
    ///      has passed — an average over zero seconds is not a number.
    function consult() external view returns (uint256 twapPrice) {
        Observation memory anchor = anchors[msg.sender];
        if (!anchor.set) revert NoAnchor(msg.sender);

        uint32 nowTimestamp = uint32(block.timestamp);
        uint32 elapsed = nowTimestamp - anchor.timestamp;
        if (elapsed == 0) revert NoElapsedTime();

        uint256 cumulative = price0CumulativeLast;
        uint32 sinceUpdate = nowTimestamp - _blockTimestampLast;
        if (sinceUpdate > 0 && _reserve0 != 0) {
            unchecked {
                // dividing first is the point: the quotient IS the UQ112x112
                // price, and it is that price which gets weighted by seconds.
                // forge-lint: disable-next-line(divide-before-multiply)
                cumulative += (uint256(_reserve1) * Q112 / uint256(_reserve0)) * sinceUpdate;
            }
        }

        uint256 averageQ112;
        unchecked {
            // Overflow of the accumulator is by design; the difference between
            // two observations is still correct modulo 2^256.
            averageQ112 = (cumulative - anchor.price0Cumulative) / elapsed;
        }
        twapPrice = Math.mulDiv(averageQ112, 1e18, Q112);
    }

    /// @notice Spot price of `token0` in `token1`, scaled by 1e18.
    /// @dev Provided for comparison against `consult`. Never price anything
    ///      valuable off this: one swap moves it, and a flash loan is one swap.
    function spotPrice() external view returns (uint256) {
        if (_reserve0 == 0) revert InsufficientLiquidity();
        return Math.mulDiv(uint256(_reserve1), 1e18, uint256(_reserve0));
    }

    // ------------------------------------------------------------- internals

    /// @dev Pulls `amount` of `token` from the caller and returns what
    ///      actually arrived.
    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) return 0;
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    /// @dev Folds elapsed time into the price accumulator at the *old*
    ///      reserves. Called before reserves change, so each price is weighted
    ///      by exactly how long it held.
    function _accumulate() internal {
        uint32 nowTimestamp = uint32(block.timestamp);
        uint32 elapsed;
        unchecked {
            elapsed = nowTimestamp - _blockTimestampLast;
        }
        if (elapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            unchecked {
                // forge-lint: disable-next-line(divide-before-multiply)
                price0CumulativeLast += (uint256(_reserve1) * Q112 / uint256(_reserve0)) * elapsed;
            }
        }
        _blockTimestampLast = nowTimestamp;
    }

    /// @dev Accumulates the oracle, then syncs reserves to real balances.
    function _update() internal {
        _accumulate();

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert ReserveOverflow();

        // casting to 'uint112' is safe because the bound is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        _reserve0 = uint112(balance0);
        // forge-lint: disable-next-line(unsafe-typecast)
        _reserve1 = uint112(balance1);
        emit Sync(_reserve0, _reserve1);
    }
}
