// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchDelegate} from "../../../src/accounts/eip7702/BatchDelegate.sol";
import {PermitToken} from "../../../src/signatures/PermitToken.sol";

contract BatchRecorder {
    error ForcedFailure(bytes32 reason);

    uint256 public calls;
    uint256 public total;
    address public lastSender;

    function record(uint256 amount) external payable returns (uint256 runningTotal) {
        calls++;
        total += amount;
        lastSender = msg.sender;
        return total;
    }

    function fail(bytes32 reason) external pure {
        revert ForcedFailure(reason);
    }
}

contract AlternateDelegate {
    error OnlySelf();

    function version() external view returns (uint256) {
        if (msg.sender != address(this)) revert OnlySelf();
        return 2;
    }
}

contract BatchTokenSpender {
    function pull(IERC20 token, address from, address to, uint256 amount) external {
        require(token.transferFrom(from, to, amount), "transfer failed");
    }
}

contract BatchDelegateTest is Test {
    uint256 internal constant ACCOUNT_KEY = 0xA11CE;

    BatchDelegate internal implementation;
    BatchRecorder internal recorder;
    PermitToken internal token;
    BatchTokenSpender internal spender;
    address internal account;

    function setUp() public {
        implementation = new BatchDelegate();
        recorder = new BatchRecorder();
        token = new PermitToken();
        spender = new BatchTokenSpender();
        account = vm.addr(ACCOUNT_KEY);

        vm.signAndAttachDelegation(address(implementation), ACCOUNT_KEY);
        vm.deal(account, 10 ether);
    }

    function test_delegatedAccountExecutesBatchAsItself() public {
        BatchDelegate.Call[] memory calls = new BatchDelegate.Call[](2);
        calls[0] = BatchDelegate.Call({
            to: address(recorder), value: 0.25 ether, data: abi.encodeCall(BatchRecorder.record, (11))
        });
        calls[1] = BatchDelegate.Call({
            to: address(recorder), value: 0.75 ether, data: abi.encodeCall(BatchRecorder.record, (31))
        });

        vm.prank(account);
        bytes[] memory results = BatchDelegate(payable(account)).executeBatch(calls);

        assertEq(recorder.calls(), 2);
        assertEq(recorder.total(), 42);
        assertEq(recorder.lastSender(), account);
        assertEq(address(recorder).balance, 1 ether);
        assertEq(account.balance, 9 ether);
        assertEq(abi.decode(results[0], (uint256)), 11);
        assertEq(abi.decode(results[1], (uint256)), 42);
    }

    function test_delegatedAccountCanReceiveEth() public {
        vm.deal(account, 0);
        address funder = makeAddr("funder");
        vm.deal(funder, 1 ether);

        vm.prank(funder);
        (bool success,) = account.call{value: 0.4 ether}("");

        assertTrue(success);
        assertEq(account.balance, 0.4 ether);
    }

    function test_externalCallerCannotInvokeDelegatedAccount() public {
        BatchDelegate.Call[] memory calls = new BatchDelegate.Call[](0);

        vm.prank(makeAddr("intruder"));
        vm.expectRevert(BatchDelegate.OnlySelf.selector);
        BatchDelegate(payable(account)).executeBatch(calls);
    }

    function test_failingCallRevertsTheEntireBatch() public {
        bytes32 reason = keccak256("expected failure");
        BatchDelegate.Call[] memory calls = new BatchDelegate.Call[](3);
        calls[0] = BatchDelegate.Call({
            to: address(recorder), value: 1 ether, data: abi.encodeCall(BatchRecorder.record, (12))
        });
        calls[1] =
            BatchDelegate.Call({to: address(recorder), value: 0, data: abi.encodeCall(BatchRecorder.fail, (reason))});
        calls[2] =
            BatchDelegate.Call({to: address(recorder), value: 0, data: abi.encodeCall(BatchRecorder.record, (30))});

        bytes memory innerReason = abi.encodeWithSelector(BatchRecorder.ForcedFailure.selector, reason);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(BatchDelegate.CallFailed.selector, 1, innerReason));
        BatchDelegate(payable(account)).executeBatch(calls);

        assertEq(recorder.calls(), 0);
        assertEq(recorder.total(), 0);
        assertEq(address(recorder).balance, 0);
        assertEq(account.balance, 10 ether);
    }

    function test_redelegatingReplacesThePreviousBehavior() public {
        AlternateDelegate replacement = new AlternateDelegate();
        vm.signAndAttachDelegation(address(replacement), ACCOUNT_KEY);

        vm.prank(account);
        assertEq(AlternateDelegate(account).version(), 2);

        BatchDelegate.Call[] memory calls = new BatchDelegate.Call[](0);
        vm.prank(account);
        vm.expectRevert();
        BatchDelegate(payable(account)).executeBatch(calls);
    }

    function testFuzz_approvalAndTransfersMatchSequentialExecution(uint96[6] memory rawAmounts) public {
        uint256 total;
        BatchDelegate.Call[] memory calls = new BatchDelegate.Call[](rawAmounts.length + 1);

        for (uint256 i; i < rawAmounts.length; ++i) {
            uint256 amount = bound(uint256(rawAmounts[i]), 0, 1_000_000 ether);
            rawAmounts[i] = uint96(amount);
            total += amount;

            address recipient = address(uint160(0x1000 + i));
            calls[i + 1] = BatchDelegate.Call({
                to: address(spender),
                value: 0,
                data: abi.encodeCall(BatchTokenSpender.pull, (IERC20(address(token)), account, recipient, amount))
            });
        }

        token.mint(account, total);
        calls[0] = BatchDelegate.Call({
            to: address(token), value: 0, data: abi.encodeCall(IERC20.approve, (address(spender), total))
        });

        vm.prank(account);
        BatchDelegate(payable(account)).executeBatch(calls);

        assertEq(token.balanceOf(account), 0);
        assertEq(token.allowance(account, address(spender)), 0);
        for (uint256 i; i < rawAmounts.length; ++i) {
            assertEq(token.balanceOf(address(uint160(0x1000 + i))), uint256(rawAmounts[i]));
        }
    }
}
