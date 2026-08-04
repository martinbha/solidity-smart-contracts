// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AmmToken} from "../../../src/defi/amm/AmmToken.sol";
import {Pair} from "../../../src/defi/amm/Pair.sol";
import {PairFactory} from "../../../src/defi/amm/PairFactory.sol";

contract PairTest is Test {
    PairFactory internal factory;
    Pair internal pair;
    AmmToken internal tokenA;
    AmmToken internal tokenB;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant SEED_0 = 100_000 ether;
    uint256 internal constant SEED_1 = 200_000 ether;

    function setUp() public {
        factory = new PairFactory();
        tokenA = new AmmToken("Token A", "TKA");
        tokenB = new AmmToken("Token B", "TKB");
        pair = Pair(factory.createPair(address(tokenA), address(tokenB)));

        _fund(alice, 10_000_000 ether);
        _fund(bob, 10_000_000 ether);

        // Resolve the sorted amounts before pranking: a `vm.prank` is spent by
        // the very next call, even a view one.
        (uint256 seed0, uint256 seed1) = (_amount0(SEED_0, SEED_1), _amount1(SEED_0, SEED_1));
        vm.prank(alice);
        pair.addLiquidity(seed0, seed1);
    }

    function _fund(address who, uint256 amount) internal {
        tokenA.mint(who, amount);
        tokenB.mint(who, amount);
        vm.startPrank(who);
        tokenA.approve(address(pair), type(uint256).max);
        tokenB.approve(address(pair), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The factory sorts tokens, so the tests address the pool by
    ///      `token0`/`token1` rather than by which token was declared first.
    function _amount0(uint256 forA, uint256 forB) internal view returns (uint256) {
        return pair.token0() == address(tokenA) ? forA : forB;
    }

    function _amount1(uint256 forA, uint256 forB) internal view returns (uint256) {
        return pair.token0() == address(tokenA) ? forB : forA;
    }

    // ------------------------------------------------------------- liquidity

    function test_FirstDepositMintsGeometricMeanMinusLockedShares() public view {
        uint256 expected = Math.sqrt(SEED_0 * SEED_1) - pair.MINIMUM_LIQUIDITY();
        assertEq(pair.balanceOf(alice), expected, "alice shares");
        assertEq(pair.balanceOf(pair.BURN_ADDRESS()), pair.MINIMUM_LIQUIDITY(), "locked shares");
        assertEq(pair.totalSupply(), expected + pair.MINIMUM_LIQUIDITY(), "total supply");
    }

    function test_MinimumLiquidityIsLockedForever() public {
        // Alice burns every share she holds; the locked shares remain, so the
        // pool can never be re-seeded from an empty supply.
        uint256 aliceShares = pair.balanceOf(alice);
        vm.prank(alice);
        pair.removeLiquidity(aliceShares);

        assertEq(pair.totalSupply(), pair.MINIMUM_LIQUIDITY(), "supply floor");
        assertGt(pair.k(), 0, "reserves floor");

        // Because supply never returns to zero, the next depositor mints
        // pro-rata against the surviving reserves — nobody can re-seed the
        // pool at a price of their choosing, which is what makes the
        // share-inflation attack unavailable.
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 add1 = pair.quote(1_000 ether, reserve0, reserve1);
        vm.prank(bob);
        uint256 shares = pair.addLiquidity(1_000 ether, add1);
        assertGt(shares, 0, "later deposits still mint");
        assertEq(pair.balanceOf(pair.BURN_ADDRESS()), pair.MINIMUM_LIQUIDITY(), "lock is never re-minted");
    }

    function test_SecondDepositMintsProRataAtCurrentRatio() public {
        uint256 supplyBefore = pair.totalSupply();
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        uint256 add0 = uint256(reserve0) / 10;
        uint256 add1 = pair.quote(add0, reserve0, reserve1);

        vm.prank(bob);
        uint256 shares = pair.addLiquidity(add0, add1);

        assertApproxEqRel(shares, supplyBefore / 10, 1e12, "bob gets a tenth of the pool");
    }

    function test_OffRatioDepositDonatesTheExcess() public {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 add0 = uint256(reserve0) / 10;
        uint256 matching1 = pair.quote(add0, reserve0, reserve1);

        // Bob overpays the second leg by 50%: shares are still minted against
        // the scarcer side, and the surplus enlarges everyone's claim.
        vm.prank(bob);
        uint256 shares = pair.addLiquidity(add0, matching1 * 3 / 2);

        assertApproxEqRel(shares, pair.totalSupply() / 11, 1e12, "minted on the scarce side");

        vm.prank(bob);
        (, uint256 out1) = pair.removeLiquidity(shares);
        assertLt(out1, matching1 * 3 / 2, "the surplus is not recoverable");
    }

    function test_AddLiquidityRevertsWhenSharesRoundToZero() public {
        vm.prank(bob);
        vm.expectRevert(Pair.InsufficientLiquidityMinted.selector);
        pair.addLiquidity(1, 0);
    }

    function test_RemoveLiquidityReturnsProRataReserves() public {
        uint256 shares = pair.balanceOf(alice);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();

        vm.prank(alice);
        (uint256 out0, uint256 out1) = pair.removeLiquidity(shares);

        assertEq(out0, Math.mulDiv(shares, reserve0, supply), "token0 share");
        assertEq(out1, Math.mulDiv(shares, reserve1, supply), "token1 share");
    }

    // ------------------------------------------------------------------ swaps

    function test_SwapOutputMatchesGetAmountOut() public {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 amountIn = 1_000 ether;
        uint256 expected = pair.getAmountOut(amountIn, reserve0, reserve1);
        address token0 = pair.token0();

        uint256 balanceBefore = _balanceOf(pair.token1(), bob);
        vm.prank(bob);
        uint256 amountOut = pair.swap(token0, amountIn, 0);

        assertEq(amountOut, expected, "quoted output");
        assertEq(_balanceOf(pair.token1(), bob) - balanceBefore, expected, "delivered output");
    }

    function test_SwapFeeGrowsK() public {
        uint256 kBefore = pair.k();
        address token0 = pair.token0();

        vm.prank(bob);
        pair.swap(token0, 1_000 ether, 0);

        assertGt(pair.k(), kBefore, "fee accrues into the invariant");
    }

    function test_SwapRevertsBelowMinAmountOut() public {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 amountIn = 1_000 ether;
        uint256 expected = pair.getAmountOut(amountIn, reserve0, reserve1);

        address token0 = pair.token0();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Pair.InsufficientOutputAmount.selector, expected, expected + 1));
        pair.swap(token0, amountIn, expected + 1);
    }

    function test_SwapRevertsOnUnknownToken() public {
        AmmToken stranger = new AmmToken("Stranger", "STR");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Pair.InvalidToken.selector, address(stranger)));
        pair.swap(address(stranger), 1 ether, 0);
    }

    function test_LargerSwapsGetWorseRates() public view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        uint256 smallOut = pair.getAmountOut(100 ether, reserve0, reserve1);
        uint256 largeOut = pair.getAmountOut(10_000 ether, reserve0, reserve1);

        // Rate per unit of input, scaled to compare like with like.
        assertGt(smallOut * 100, largeOut, "price impact punishes size");
    }

    function test_RoundTripSwapLosesTheFeeToLps() public {
        uint256 amountIn = 1_000 ether;
        uint256 before = _balanceOf(pair.token0(), bob);

        vm.startPrank(bob);
        uint256 out1 = pair.swap(pair.token0(), amountIn, 0);
        pair.swap(pair.token1(), out1, 0);
        vm.stopPrank();

        // Two 0.30% fees plus price impact: a round trip is always a loss.
        assertLt(_balanceOf(pair.token0(), bob), before, "arbitrage-free round trip");
    }

    function test_LiquidityRoundTripRecoversPrincipalPlusFees() public {
        (uint256 add0, uint256 add1) = (_amount0(10_000 ether, 20_000 ether), _amount1(10_000 ether, 20_000 ether));
        vm.prank(bob);
        uint256 shares = pair.addLiquidity(add0, add1);

        // Alice trades back and forth in both directions, paying fees into
        // the pool. Round-tripping each way in turn grows both reserves.
        vm.startPrank(alice);
        for (uint256 i = 0; i < 3; i++) {
            uint256 out1 = pair.swap(pair.token0(), 5_000 ether, 0);
            pair.swap(pair.token1(), out1, 0);
            uint256 out0 = pair.swap(pair.token1(), 5_000 ether, 0);
            pair.swap(pair.token0(), out0, 0);
        }
        vm.stopPrank();

        vm.prank(bob);
        (uint256 out0, uint256 out1_) = pair.removeLiquidity(shares);

        // Bob deposited at the pool ratio and the price came back to it, so
        // both legs should exceed principal by his share of the fees.
        assertGt(out0, add0, "token0 principal + fees");
        assertGt(out1_, add1, "token1 principal + fees");
    }

    // ----------------------------------------------------------------- oracle

    function test_TwapResistsALastMinuteSpotMove() public {
        pair.updateOracle();

        // An hour of calm at the seeded price.
        address token0 = pair.token0();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        pair.swap(token0, 1 ether, 0); // negligible, folds in the hour

        uint256 twapBefore = pair.consult();
        uint256 spotBefore = pair.spotPrice();

        // Now a whale slams the pool in the very next second.
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        pair.swap(token0, 50_000 ether, 0);

        uint256 twapAfter = pair.consult();
        uint256 spotAfter = pair.spotPrice();

        assertLt(spotAfter, spotBefore * 60 / 100, "spot moved hugely");
        assertApproxEqRel(twapAfter, twapBefore, 1e15, "twap barely moved"); // 0.1%
    }

    function test_TwapTracksAPersistentPriceChange() public {
        pair.updateOracle();
        uint256 spotStart = pair.spotPrice();
        address token0 = pair.token0();

        vm.prank(bob);
        pair.swap(token0, 20_000 ether, 0);
        uint256 spotAfterTrade = pair.spotPrice();

        // Hold the new price for a day and the average converges onto it.
        vm.warp(block.timestamp + 1 days);

        uint256 twap = pair.consult();
        assertLt(twap, spotStart, "average followed the move down");
        assertApproxEqRel(twap, spotAfterTrade, 1e15, "converges on the sustained price");
    }

    function test_ConsultRevertsOverAZeroLengthWindow() public {
        pair.updateOracle();
        vm.expectRevert(Pair.NoElapsedTime.selector);
        pair.consult();
    }

    // ---------------------------------------------------------------- factory

    function test_FactoryDeploysToTheComputedAddress() public {
        AmmToken tokenC = new AmmToken("Token C", "TKC");
        address predicted = factory.computePairAddress(address(tokenA), address(tokenC));
        address deployed = factory.createPair(address(tokenC), address(tokenA));

        assertEq(deployed, predicted, "CREATE2 address is knowable in advance");
    }

    function test_FactoryReturnsTheSamePairInBothOrderings() public view {
        assertEq(factory.getPair(address(tokenA), address(tokenB)), address(pair));
        assertEq(factory.getPair(address(tokenB), address(tokenA)), address(pair));
        assertEq(factory.allPairsLength(), 1);
    }

    function test_FactoryRejectsADuplicatePair() public {
        vm.expectRevert(abi.encodeWithSelector(PairFactory.PairExists.selector, address(pair)));
        factory.createPair(address(tokenB), address(tokenA));
    }

    function test_FactoryRejectsIdenticalAndZeroTokens() public {
        vm.expectRevert(PairFactory.IdenticalTokens.selector);
        factory.createPair(address(tokenA), address(tokenA));

        vm.expectRevert(PairFactory.ZeroAddressToken.selector);
        factory.createPair(address(0), address(tokenA));
    }

    function test_PairCannotBeReinitialized() public {
        vm.prank(address(factory));
        vm.expectRevert(Pair.AlreadyInitialized.selector);
        pair.initialize(address(tokenA), address(tokenB));

        vm.expectRevert(Pair.NotFactory.selector);
        pair.initialize(address(tokenA), address(tokenB));
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_GetAmountOutNeverBreaksTheInvariant(uint256 amountIn) public view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        amountIn = bound(amountIn, 1, 1_000_000 ether);

        uint256 amountOut = pair.getAmountOut(amountIn, reserve0, reserve1);
        assertLt(amountOut, reserve1, "cannot drain the pool");
        assertGe(
            (uint256(reserve0) + amountIn) * (uint256(reserve1) - amountOut),
            uint256(reserve0) * uint256(reserve1),
            "k never decreases"
        );
    }

    function testFuzz_GetAmountInCoversTheRequestedOutput(uint256 amountOut) public view {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        amountOut = bound(amountOut, 1, uint256(reserve1) / 2);

        uint256 amountIn = pair.getAmountIn(amountOut, reserve0, reserve1);
        assertGe(pair.getAmountOut(amountIn, reserve0, reserve1), amountOut, "rounds in the pool's favour");
    }

    function _balanceOf(address token, address who) internal view returns (uint256) {
        return AmmToken(token).balanceOf(who);
    }
}
