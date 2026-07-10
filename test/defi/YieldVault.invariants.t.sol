// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultAsset} from "../../src/defi/VaultAsset.sol";
import {MockYieldSource} from "../../src/defi/MockYieldSource.sol";
import {YieldVault} from "../../src/defi/YieldVault.sol";

/// @notice Drives the vault with random deposits, mints, withdrawals, redeems,
///         harvests, rate changes, and hostile direct donations, so the
///         invariants below are checked against arbitrary interleavings.
contract VaultHandler is Test {
    YieldVault public vault;
    VaultAsset public asset;
    MockYieldSource public source;
    address public owner;

    address[] public actors;

    constructor(YieldVault vault_, VaultAsset asset_, MockYieldSource source_, address owner_) {
        vault = vault_;
        asset = asset_;
        source = source_;
        owner = owner_;
        for (uint256 i = 0; i < 4; i++) {
            address actor = address(uint160(0xACC0 + i));
            actors.push(actor);
            asset.mint(actor, 1_000_000 ether);
            vm.prank(actor);
            asset.approve(address(vault), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        amount = bound(amount, 0, asset.balanceOf(actor));
        if (amount == 0) return;
        vm.prank(actor);
        vault.deposit(amount, actor);
    }

    function mintShares(uint256 seed, uint256 shares) external {
        address actor = _actor(seed);
        uint256 maxShares = vault.convertToShares(asset.balanceOf(actor));
        shares = bound(shares, 0, maxShares);
        // convertToShares rounds down but previewMint rounds up, so the top of
        // the range can cost 1 wei more than the actor holds — skip those.
        if (shares == 0 || vault.previewMint(shares) > asset.balanceOf(actor)) return;
        vm.prank(actor);
        vault.mint(shares, actor);
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        amount = bound(amount, 0, vault.maxWithdraw(actor));
        if (amount == 0) return;
        vm.prank(actor);
        vault.withdraw(amount, actor, actor);
    }

    function redeem(uint256 seed, uint256 shares) external {
        address actor = _actor(seed);
        shares = bound(shares, 0, vault.maxRedeem(actor));
        if (shares == 0) return;
        vm.prank(actor);
        vault.redeem(shares, actor, actor);
    }

    function harvest() external {
        vault.harvest();
    }

    function setYieldRate(uint256 bps) external {
        vm.prank(owner);
        vault.setYieldRate(bound(bps, 0, vault.MAX_YIELD_RATE_BPS()));
    }

    /// @notice Hostile donation straight to the vault — the inflation-attack
    ///         primitive. Invariants must survive it.
    function donate(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        amount = bound(amount, 0, asset.balanceOf(actor));
        if (amount == 0) return;
        vm.prank(actor);
        asset.transfer(address(vault), amount);
    }

    function sumShareBalances() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += vault.balanceOf(actors[i]);
        }
    }

    function sumRedeemableAssets() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += vault.previewRedeem(vault.balanceOf(actors[i]));
        }
    }
}

contract YieldVaultInvariantTest is Test {
    VaultAsset internal asset;
    MockYieldSource internal source;
    YieldVault internal vault;
    VaultHandler internal handler;

    function setUp() public {
        asset = new VaultAsset();
        source = new MockYieldSource(IERC20(address(asset)));
        vault = new YieldVault(IERC20(address(asset)), source);
        source.setVault(address(vault));
        vault.setYieldRate(500);

        // Finite yield reserve: harvests pay from this until it runs dry.
        asset.mint(address(this), 10_000_000 ether);
        asset.approve(address(source), type(uint256).max);
        source.fund(10_000_000 ether);

        handler = new VaultHandler(vault, asset, source, address(this));
        targetContract(address(handler));
    }

    /// @notice Solvency: the vault always holds at least what it would owe if
    ///         every holder redeemed at the current price. Redemption previews
    ///         round against the holder, so the sum can never exceed reality —
    ///         any violation means shares were minted out of thin air.
    function invariant_SolventForFullRedemption() public view {
        assertLe(handler.sumRedeemableAssets(), vault.totalAssets());
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets());
    }

    /// @notice Share conservation: every share is accounted to an actor. Only
    ///         handler actors ever receive shares, so their balances must sum
    ///         exactly to totalSupply under any action sequence.
    function invariant_SharesFullyAccounted() public view {
        assertEq(handler.sumShareBalances(), vault.totalSupply());
    }

    /// @notice totalAssets is exactly the vault's asset balance (no phantom
    ///         accounting): deposits, withdrawals, harvests, and donations all
    ///         reconcile to the ERC20 balance.
    function invariant_TotalAssetsMatchesBalance() public view {
        assertEq(vault.totalAssets(), asset.balanceOf(address(vault)));
    }
}
