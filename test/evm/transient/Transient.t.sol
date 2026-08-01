// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransientVault} from "../../../src/evm/transient/TransientReentrancyGuard.sol";
import {StorageVault} from "../../../src/evm/transient/StorageReentrancyGuard.sol";
import {FlashAccountant, IFlashAccountantCallback} from "../../../src/evm/transient/FlashAccountant.sol";
import {PermitToken} from "../../../src/signatures/PermitToken.sol";

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

contract FlashBorrower is IFlashAccountantCallback {
    struct Action {
        uint256 amount;
        bool settle;
        bool nestedLock;
    }

    FlashAccountant public immutable accountant;
    IERC20 public immutable token;
    bool public nestedLockBlocked;

    constructor(FlashAccountant accountant_, IERC20 token_) {
        accountant = accountant_;
        token = token_;
        require(token_.approve(address(accountant_), type(uint256).max), "approve failed");
    }

    function run(Action[] calldata actions) external {
        accountant.lock(abi.encode(actions));
    }

    function lockAcquired(bytes calldata data) external {
        require(msg.sender == address(accountant), "not accountant");
        Action[] memory actions = abi.decode(data, (Action[]));

        for (uint256 i; i < actions.length; ++i) {
            if (actions[i].nestedLock) {
                try accountant.lock("") {}
                catch (bytes memory reason) {
                    nestedLockBlocked = _selector(reason) == FlashAccountant.AlreadyLocked.selector;
                }
            }
            if (actions[i].amount != 0) accountant.take(address(token), actions[i].amount);
            if (actions[i].settle && accountant.debt(address(this), address(token)) != 0) {
                accountant.settle(address(token));
            }
        }
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }
}

contract TransientStorageTest is Test {
    TransientVault internal transientVault;
    StorageVault internal storageVault;
    FlashAccountant internal accountant;
    PermitToken internal token;
    FlashBorrower internal borrower;

    function setUp() public {
        transientVault = new TransientVault();
        storageVault = new StorageVault();
        accountant = new FlashAccountant();
        token = new PermitToken();
        borrower = new FlashBorrower(accountant, IERC20(address(token)));

        token.mint(address(accountant), 1_000_000 ether);
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

    function test_flashSessionCanTakeAndSettleToZero() public {
        uint256 balanceBefore = token.balanceOf(address(accountant));
        FlashBorrower.Action[] memory actions = new FlashBorrower.Action[](1);
        actions[0] = FlashBorrower.Action({amount: 100 ether, settle: true, nestedLock: false});

        borrower.run(actions);

        assertEq(token.balanceOf(address(accountant)), balanceBefore);
        assertEq(token.balanceOf(address(borrower)), 0);
        assertEq(accountant.currentLocker(), address(0));
        assertEq(accountant.debt(address(borrower), address(token)), 0);
        assertEq(accountant.outstandingDebtCount(), 0);
    }

    function test_unsettledDebtRevertsTheWholeSession() public {
        uint256 balanceBefore = token.balanceOf(address(accountant));
        FlashBorrower.Action[] memory actions = new FlashBorrower.Action[](1);
        actions[0] = FlashBorrower.Action({amount: 100 ether, settle: false, nestedLock: false});

        vm.expectRevert(abi.encodeWithSelector(FlashAccountant.UnsettledDebt.selector, 1));
        borrower.run(actions);

        assertEq(token.balanceOf(address(accountant)), balanceBefore);
        assertEq(token.balanceOf(address(borrower)), 0);
        assertEq(accountant.currentLocker(), address(0));
    }

    function test_nestedLockIsRejectedWhileOuterSessionContinues() public {
        FlashBorrower.Action[] memory actions = new FlashBorrower.Action[](1);
        actions[0] = FlashBorrower.Action({amount: 0, settle: false, nestedLock: true});

        borrower.run(actions);

        assertTrue(borrower.nestedLockBlocked());
        assertEq(accountant.currentLocker(), address(0));
    }

    function test_onlyContractsCanOpenSessions() public {
        address caller = makeAddr("caller");

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(FlashAccountant.InvalidLocker.selector, caller));
        accountant.lock("");
    }

    function test_takeAndSettleRequireTheCurrentLocker() public {
        vm.expectRevert(abi.encodeWithSelector(FlashAccountant.NotLocker.selector, address(this), address(0)));
        accountant.take(address(token), 1);

        vm.expectRevert(abi.encodeWithSelector(FlashAccountant.NotLocker.selector, address(this), address(0)));
        accountant.settle(address(token));
    }
}
