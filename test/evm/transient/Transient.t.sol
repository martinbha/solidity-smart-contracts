// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransientVault} from "../../../src/evm/transient/TransientReentrancyGuard.sol";
import {StorageVault} from "../../../src/evm/transient/StorageReentrancyGuard.sol";

interface IGuardedVault {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function guardedNoop() external;
    function balances(address account) external view returns (uint256);
}

contract ReentrantWithdrawer {
    IGuardedVault public immutable vault;

    uint256 private _withdrawAmount;
    bool public attempted;
    bool public blocked;

    constructor(IGuardedVault vault_) {
        vault = vault_;
    }

    function attack() external payable {
        _withdrawAmount = msg.value;
        vault.deposit{value: msg.value}();
        vault.withdraw(msg.value);
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;

        try vault.withdraw(_withdrawAmount) {}
        catch {
            blocked = true;
        }
    }
}

contract TransientStorageTest is Test {
    TransientVault internal transientVault;
    StorageVault internal storageVault;

    function setUp() public {
        transientVault = new TransientVault();
        storageVault = new StorageVault();
    }

    function test_transientGuardBlocksReentrantWithdrawal() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(IGuardedVault(address(transientVault)));

        attacker.attack{value: 1 ether}();

        assertTrue(attacker.attempted());
        assertTrue(attacker.blocked());
        assertEq(address(attacker).balance, 1 ether);
        assertEq(transientVault.balances(address(attacker)), 0);
        assertEq(address(transientVault).balance, 0);
    }

    function test_transientGuardClearsAfterEachCall() public {
        transientVault.guardedNoop();
        transientVault.guardedNoop();
    }

    function test_storageBaselineBlocksTheSameAttack() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(IGuardedVault(address(storageVault)));

        attacker.attack{value: 1 ether}();

        assertTrue(attacker.attempted());
        assertTrue(attacker.blocked());
        assertEq(address(attacker).balance, 1 ether);
        assertEq(storageVault.balances(address(attacker)), 0);
    }
}
