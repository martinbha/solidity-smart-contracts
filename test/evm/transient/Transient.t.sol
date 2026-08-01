// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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

contract SenderFeeToken is ERC20 {
    constructor() ERC20("Sender Fee Token", "SFT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && to != address(0)) super._update(from, address(0), amount / 10);
    }
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

contract MultiTokenBorrower is IFlashAccountantCallback {
    FlashAccountant public immutable accountant;
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    uint256 public observedDebtCount;

    constructor(FlashAccountant accountant_, IERC20 tokenA_, IERC20 tokenB_) {
        accountant = accountant_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        require(tokenA_.approve(address(accountant_), type(uint256).max), "approve A failed");
        require(tokenB_.approve(address(accountant_), type(uint256).max), "approve B failed");
    }

    function run(bool settleSecondToken) external {
        accountant.lock(abi.encode(settleSecondToken));
    }

    function lockAcquired(bytes calldata data) external {
        require(msg.sender == address(accountant), "not accountant");
        bool settleSecondToken = abi.decode(data, (bool));

        accountant.take(address(tokenA), 10 ether);
        accountant.take(address(tokenB), 20 ether);
        observedDebtCount = accountant.outstandingDebtCount();
        accountant.settle(address(tokenA));
        if (settleSecondToken) accountant.settle(address(tokenB));
    }
}

contract TransientStorageTest is Test {
    TransientVault internal transientVault;
    StorageVault internal storageVault;
    FlashAccountant internal accountant;
    PermitToken internal token;
    PermitToken internal secondToken;
    FlashBorrower internal borrower;
    MultiTokenBorrower internal multiTokenBorrower;

    function setUp() public {
        transientVault = new TransientVault();
        storageVault = new StorageVault();
        accountant = new FlashAccountant();
        token = new PermitToken();
        secondToken = new PermitToken();
        borrower = new FlashBorrower(accountant, IERC20(address(token)));
        multiTokenBorrower = new MultiTokenBorrower(accountant, IERC20(address(token)), IERC20(address(secondToken)));

        token.mint(address(accountant), 1_000_000 ether);
        secondToken.mint(address(accountant), 1_000_000 ether);
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

    function test_transientGuardCostsLessGasThanStorageGuard() public {
        uint256 gasBefore = gasleft();
        transientVault.guardedNoop();
        uint256 transientGas = gasBefore - gasleft();

        gasBefore = gasleft();
        storageVault.guardedNoop();
        uint256 storageGas = gasBefore - gasleft();

        uint256 gasSaved = storageGas > transientGas ? storageGas - transientGas : 0;
        emit log_named_uint("transient guard gas", transientGas);
        emit log_named_uint("storage guard gas", storageGas);
        emit log_named_uint("gas saved", gasSaved);

        assertLt(transientGas, storageGas);
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

    function test_senderTransferFeeCannotLeaveTheAccountantShort() public {
        SenderFeeToken feeToken = new SenderFeeToken();
        FlashBorrower feeBorrower = new FlashBorrower(accountant, IERC20(address(feeToken)));
        feeToken.mint(address(accountant), 1_000 ether);

        FlashBorrower.Action[] memory actions = new FlashBorrower.Action[](1);
        actions[0] = FlashBorrower.Action({amount: 100 ether, settle: true, nestedLock: false});

        vm.expectRevert(
            abi.encodeWithSelector(FlashAccountant.IncorrectTake.selector, address(feeToken), 100 ether, 110 ether)
        );
        feeBorrower.run(actions);

        assertEq(feeToken.balanceOf(address(accountant)), 1_000 ether);
        assertEq(feeToken.balanceOf(address(feeBorrower)), 0);
        assertEq(accountant.currentLocker(), address(0));
        assertEq(accountant.outstandingDebtCount(), 0);
    }

    function test_multipleTokenDebtsAreCountedAndSettledIndependently() public {
        uint256 balanceABefore = token.balanceOf(address(accountant));
        uint256 balanceBBefore = secondToken.balanceOf(address(accountant));

        multiTokenBorrower.run(true);

        assertEq(multiTokenBorrower.observedDebtCount(), 2);
        assertEq(token.balanceOf(address(accountant)), balanceABefore);
        assertEq(secondToken.balanceOf(address(accountant)), balanceBBefore);
        assertEq(accountant.outstandingDebtCount(), 0);
    }

    function test_oneUnsettledTokenRevertsAMultiTokenSession() public {
        uint256 balanceABefore = token.balanceOf(address(accountant));
        uint256 balanceBBefore = secondToken.balanceOf(address(accountant));

        vm.expectRevert(abi.encodeWithSelector(FlashAccountant.UnsettledDebt.selector, 1));
        multiTokenBorrower.run(false);

        assertEq(token.balanceOf(address(accountant)), balanceABefore);
        assertEq(secondToken.balanceOf(address(accountant)), balanceBBefore);
        assertEq(accountant.outstandingDebtCount(), 0);
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

    function testFuzz_randomTakeSettleSequencesSucceedOnlyAtZeroDebt(
        uint96[8] memory rawAmounts,
        bool[8] memory settles
    ) public {
        FlashBorrower.Action[] memory actions = new FlashBorrower.Action[](rawAmounts.length);
        uint256 pendingDebt;

        for (uint256 i; i < rawAmounts.length; ++i) {
            uint256 amount = bound(uint256(rawAmounts[i]), 1, 100_000 ether);
            actions[i] = FlashBorrower.Action({amount: amount, settle: settles[i], nestedLock: false});
            pendingDebt += amount;
            if (settles[i]) pendingDebt = 0;
        }

        uint256 accountantBalance = token.balanceOf(address(accountant));
        if (pendingDebt == 0) {
            borrower.run(actions);
        } else {
            vm.expectRevert(abi.encodeWithSelector(FlashAccountant.UnsettledDebt.selector, 1));
            borrower.run(actions);
        }

        assertEq(token.balanceOf(address(accountant)), accountantBalance);
        assertEq(token.balanceOf(address(borrower)), 0);
        assertEq(accountant.currentLocker(), address(0));
        assertEq(accountant.outstandingDebtCount(), 0);
    }
}
