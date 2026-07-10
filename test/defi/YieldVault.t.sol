// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {VaultAsset} from "../../src/defi/VaultAsset.sol";
import {MockYieldSource} from "../../src/defi/MockYieldSource.sol";
import {YieldVault} from "../../src/defi/YieldVault.sol";

contract YieldVaultTest is Test {
    VaultAsset internal asset;
    MockYieldSource internal source;
    YieldVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant SOURCE_RESERVE = 1_000_000 ether;

    function setUp() public {
        asset = new VaultAsset();
        source = new MockYieldSource(IERC20(address(asset)));
        vault = new YieldVault(IERC20(address(asset)), source);
        source.setVault(address(vault));

        // Give the source a deep reserve so harvests pay in full unless a test
        // deliberately drains it.
        asset.mint(address(this), SOURCE_RESERVE);
        asset.approve(address(source), SOURCE_RESERVE);
        source.fund(SOURCE_RESERVE);

        vault.setYieldRate(1_000); // 10% per harvest

        _dealAndApprove(alice, 10_000 ether);
        _dealAndApprove(bob, 10_000 ether);
        _dealAndApprove(attacker, 1_000_000 ether);
    }

    function _dealAndApprove(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.prank(who);
        asset.approve(address(vault), type(uint256).max);
    }

    // ---------------------------------------------------------------- previews

    function test_DepositMintsPreviewedShares() public {
        uint256 assets = 1_234 ether;
        uint256 promised = vault.previewDeposit(assets);
        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);
        assertEq(shares, promised);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_MintPullsPreviewedAssets() public {
        uint256 shares = 500 ether;
        uint256 promised = vault.previewMint(shares);
        uint256 before = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = vault.mint(shares, alice);
        assertEq(paid, promised);
        assertEq(before - asset.balanceOf(alice), paid);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_WithdrawBurnsPreviewedShares() public {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);
        vault.harvest(); // make the exchange rate non-trivial

        uint256 assetsOut = 400 ether;
        uint256 promised = vault.previewWithdraw(assetsOut);
        uint256 sharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 burned = vault.withdraw(assetsOut, alice, alice);
        assertEq(burned, promised);
        assertEq(sharesBefore - vault.balanceOf(alice), burned);
    }

    function test_RedeemPaysPreviewedAssets() public {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);
        vault.harvest();

        uint256 shares = vault.balanceOf(alice) / 3;
        uint256 promised = vault.previewRedeem(shares);
        uint256 before = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = vault.redeem(shares, alice, alice);
        assertEq(paid, promised);
        assertEq(asset.balanceOf(alice) - before, paid);
    }

    // ------------------------------------------------------------------ yield

    function test_HarvestRaisesSharePrice() public {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);

        uint256 priceBefore = vault.convertToAssets(1e18);
        uint256 received = vault.harvest();
        uint256 priceAfter = vault.convertToAssets(1e18);

        assertEq(received, 100 ether); // 10% of 1000
        assertGt(priceAfter, priceBefore);
    }

    function test_EarlyDepositorEarnsMoreThanLate() public {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);

        vault.harvest(); // only alice is in for this accrual

        vm.prank(bob);
        vault.deposit(1_000 ether, bob);

        vault.harvest(); // both share this one

        uint256 aliceAssets = vault.previewRedeem(vault.balanceOf(alice));
        uint256 bobAssets = vault.previewRedeem(vault.balanceOf(bob));

        assertGt(aliceAssets, bobAssets);
        // Both must at least keep principal (modulo 1 wei of rounding).
        assertGe(aliceAssets, 1_000 ether);
        assertGe(bobAssets, 1_000 ether - 1);
    }

    function test_HarvestWithDrainedSourceIsNoOp() public {
        // Fresh source with nothing in it.
        MockYieldSource empty = new MockYieldSource(IERC20(address(asset)));
        YieldVault v = new YieldVault(IERC20(address(asset)), empty);
        empty.setVault(address(v));
        v.setYieldRate(1_000);

        vm.startPrank(alice);
        asset.approve(address(v), type(uint256).max);
        v.deposit(100 ether, alice);
        vm.stopPrank();

        uint256 received = v.harvest();
        assertEq(received, 0);
        assertEq(v.totalAssets(), 100 ether);
    }

    function test_SetYieldRateOnlyOwnerAndCapped() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setYieldRate(1);

        vm.expectRevert(abi.encodeWithSelector(YieldVault.YieldRateTooHigh.selector, 10_001));
        vault.setYieldRate(10_001);

        vault.setYieldRate(10_000);
        assertEq(vault.yieldRateBps(), 10_000);
    }

    // ------------------------------------------------------- inflation attack

    /// @notice Regression test for the classic first-depositor inflation attack:
    ///         attacker deposits 1 wei, donates a fortune directly to the vault
    ///         to blow up the share price, then the victim deposits. With the
    ///         decimal offset the victim's rounding loss must stay negligible
    ///         and the attacker must not profit.
    function test_InflationAttackIsUnprofitable() public {
        uint256 donation = 100_000 ether;
        uint256 victimDeposit = 1_000 ether;

        vm.startPrank(attacker);
        vault.deposit(1, attacker);
        asset.transfer(address(vault), donation); // donation, not deposit
        vm.stopPrank();

        vm.prank(bob);
        uint256 victimShares = vault.deposit(victimDeposit, bob);

        // The victim must receive shares and be able to exit with nearly all
        // principal: loss bounded well under 0.1% even against a 100k donation.
        assertGt(victimShares, 0);
        uint256 victimAssets = vault.previewRedeem(victimShares);
        assertGt(victimAssets, victimDeposit * 999 / 1000);

        // The attacker redeems everything and must come out behind: the
        // donation is mostly captured by virtual shares, not recoverable.
        vm.startPrank(attacker);
        uint256 attackerOut = vault.redeem(vault.balanceOf(attacker), attacker, attacker);
        vm.stopPrank();
        assertLt(attackerOut, donation + 1);

        uint256 attackerLoss = donation + 1 - attackerOut;
        uint256 victimLoss = victimDeposit - victimAssets;
        assertGt(attackerLoss, victimLoss); // strictly value-destroying
    }

    // --------------------------------------------------------------- rounding

    /// @notice A deposit followed by a full redeem must never return more than
    ///         was put in: rounding always favors the vault.
    function testFuzz_RoundTripNeverProfits(uint256 seedAssets, uint256 depositAmount) public {
        // Random pre-existing state so the exchange rate isn't always 1:1.
        seedAssets = bound(seedAssets, 1, 1_000_000 ether);
        depositAmount = bound(depositAmount, 1, 10_000 ether);

        vm.prank(alice);
        vault.deposit(bound(seedAssets, 1, 10_000 ether), alice);
        vault.harvest();

        vm.startPrank(bob);
        uint256 shares = vault.deposit(depositAmount, bob);
        uint256 back = shares == 0 ? 0 : vault.redeem(shares, bob, bob);
        vm.stopPrank();

        assertLe(back, depositAmount);
    }

    /// @notice Mint-then-withdraw round trip must also favor the vault.
    function testFuzz_MintWithdrawRoundTripNeverProfits(uint256 shares) public {
        shares = bound(shares, 1, 10_000 ether);

        vm.prank(alice);
        vault.deposit(3_333 ether, alice);
        vault.harvest();

        vm.startPrank(bob);
        uint256 paid = vault.mint(shares, bob);
        uint256 maxOut = vault.maxWithdraw(bob);
        uint256 burned = maxOut == 0 ? 0 : vault.withdraw(maxOut, bob, bob);
        vm.stopPrank();

        assertLe(maxOut, paid);
        assertLe(burned, shares);
    }

    // ------------------------------------------------------------------ maxes

    function test_MaxWithdrawRespected() public {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);
        vault.harvest();

        uint256 max = vault.maxWithdraw(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, max + 1, max)
        );
        vault.withdraw(max + 1, alice, alice);

        vm.prank(alice);
        vault.withdraw(max, alice, alice); // exactly max succeeds
    }

    function test_MaxRedeemRespected() public {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);

        uint256 max = vault.maxRedeem(alice);
        assertEq(max, vault.balanceOf(alice));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, max + 1, max)
        );
        vault.redeem(max + 1, alice, alice);

        vm.prank(alice);
        vault.redeem(max, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ----------------------------------------------------------- yield source

    function test_YieldSourceBindsVaultOnce() public {
        MockYieldSource s = new MockYieldSource(IERC20(address(asset)));
        s.setVault(address(vault));
        vm.expectRevert(MockYieldSource.VaultAlreadySet.selector);
        s.setVault(address(this));
    }

    function test_YieldSourceRejectsStrangers() public {
        vm.prank(alice);
        vm.expectRevert(MockYieldSource.NotVault.selector);
        source.payYield(1 ether);
    }
}
