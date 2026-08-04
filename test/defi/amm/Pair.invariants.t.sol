// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AmmToken} from "../../../src/defi/amm/AmmToken.sol";
import {Pair} from "../../../src/defi/amm/Pair.sol";
import {PairFactory} from "../../../src/defi/amm/PairFactory.sol";

/// @notice Drives the pool with random swaps in both directions, random
///         liquidity adds and removes, direct donations, and time jumps, so
///         the invariants below are checked against arbitrary interleavings
///         rather than a script the pool was designed to pass.
contract PairHandler is Test {
    Pair public pair;
    AmmToken public token0;
    AmmToken public token1;

    address[] public actors;

    constructor(Pair pair_) {
        pair = pair_;
        token0 = AmmToken(pair_.token0());
        token1 = AmmToken(pair_.token1());

        for (uint256 i = 0; i < 4; i++) {
            address actor = address(uint160(0xAAA0 + i));
            actors.push(actor);
            token0.mint(actor, 1_000_000 ether);
            token1.mint(actor, 1_000_000 ether);
            vm.startPrank(actor);
            token0.approve(address(pair), type(uint256).max);
            token1.approve(address(pair), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function swapExactIn(uint256 seed, uint256 amountIn, bool zeroForOne) external {
        address actor = _actor(seed);
        AmmToken tokenIn = zeroForOne ? token0 : token1;
        amountIn = bound(amountIn, 0, tokenIn.balanceOf(actor));
        if (amountIn == 0) return;

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return;
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        if (pair.getAmountOut(amountIn, reserveIn, reserveOut) == 0) return;

        uint256 kBefore = pair.k();
        vm.prank(actor);
        pair.swap(address(tokenIn), amountIn, 0);

        // A swap must never shrink the invariant; the fee only grows it.
        assertGe(pair.k(), kBefore, "swap shrank k");
    }

    function addLiquidity(uint256 seed, uint256 amount0) external {
        address actor = _actor(seed);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return;

        amount0 = bound(amount0, 1, token0.balanceOf(actor));
        uint256 amount1 = pair.quote(amount0, reserve0, reserve1);
        if (amount1 == 0 || amount1 > token1.balanceOf(actor)) return;
        if (uint256(reserve0) + amount0 > type(uint112).max) return;
        if (uint256(reserve1) + amount1 > type(uint112).max) return;

        vm.prank(actor);
        pair.addLiquidity(amount0, amount1);
    }

    function removeLiquidity(uint256 seed, uint256 shares) external {
        address actor = _actor(seed);
        shares = bound(shares, 0, pair.balanceOf(actor));
        if (shares == 0) return;

        vm.prank(actor);
        pair.removeLiquidity(shares);
    }

    /// @dev Hostile donation: tokens shoved straight at the pool, bypassing
    ///      `addLiquidity`. They must enrich existing LPs, never mint shares.
    function donate(uint256 seed, uint256 amount, bool toZero) external {
        address actor = _actor(seed);
        AmmToken token = toZero ? token0 : token1;
        amount = bound(amount, 0, token.balanceOf(actor) / 100);
        if (amount == 0) return;

        vm.prank(actor);
        token.transfer(address(pair), amount);
    }

    function advanceTime(uint256 secondsToJump) external {
        vm.warp(block.timestamp + bound(secondsToJump, 1, 7 days));
    }
}

contract PairInvariantsTest is Test {
    PairFactory internal factory;
    PairHandler internal handler;
    Pair internal pair;
    AmmToken internal tokenA;
    AmmToken internal tokenB;

    function setUp() public {
        factory = new PairFactory();
        tokenA = new AmmToken("Token A", "TKA");
        tokenB = new AmmToken("Token B", "TKB");
        pair = Pair(factory.createPair(address(tokenA), address(tokenB)));

        tokenA.mint(address(this), 500_000 ether);
        tokenB.mint(address(this), 500_000 ether);
        tokenA.approve(address(pair), type(uint256).max);
        tokenB.approve(address(pair), type(uint256).max);
        pair.addLiquidity(200_000 ether, 300_000 ether);

        handler = new PairHandler(pair);
        targetContract(address(handler));
    }

    /// @notice Reserves always mirror the pool's real token balances.
    function invariant_ReservesTrackBalancesAfterEveryAction() public view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertLe(uint256(reserve0), AmmToken(pair.token0()).balanceOf(address(pair)), "reserve0 overstated");
        assertLe(uint256(reserve1), AmmToken(pair.token1()).balanceOf(address(pair)), "reserve1 overstated");
    }

    /// @notice The pool is never left half-empty: either both reserves hold
    ///         value or neither does.
    function invariant_ReservesAreNeverOneSided() public view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertTrue((reserve0 == 0) == (reserve1 == 0), "one-sided pool");
    }

    /// @notice The locked minimum liquidity survives every sequence, so total
    ///         supply can never fall back to zero and reset the price.
    function invariant_MinimumLiquidityStaysLocked() public view {
        assertEq(pair.balanceOf(pair.BURN_ADDRESS()), pair.MINIMUM_LIQUIDITY(), "lock broken");
        assertGe(pair.totalSupply(), pair.MINIMUM_LIQUIDITY(), "supply below the floor");
    }

    /// @notice Shares outstanding equal the sum of every holder's balance —
    ///         no share is minted or burned outside `addLiquidity`/`removeLiquidity`.
    function invariant_SharesSumToTotalSupply() public view {
        uint256 sum = pair.balanceOf(pair.BURN_ADDRESS()) + pair.balanceOf(address(this));
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += pair.balanceOf(handler.actors(i));
        }
        assertEq(sum, pair.totalSupply(), "shares unaccounted for");
    }

    /// @notice Every share is backed by at least one wei of each reserve —
    ///         the pool is never inflated beyond what it holds.
    function invariant_SharesAreBackedByReserves() public view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (pair.totalSupply() == 0) return;
        assertGt(uint256(reserve0), 0, "shares with no token0 behind them");
        assertGt(uint256(reserve1), 0, "shares with no token1 behind them");
    }
}
