// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BatchDelegate} from "../../../src/accounts/eip7702/BatchDelegate.sol";

contract BatchRecorder {
    uint256 public calls;
    uint256 public total;
    address public lastSender;

    function record(uint256 amount) external payable returns (uint256 runningTotal) {
        calls++;
        total += amount;
        lastSender = msg.sender;
        return total;
    }
}

contract BatchDelegateTest is Test {
    uint256 internal constant ACCOUNT_KEY = 0xA11CE;

    BatchDelegate internal implementation;
    BatchRecorder internal recorder;
    address internal account;

    function setUp() public {
        implementation = new BatchDelegate();
        recorder = new BatchRecorder();
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
        assertEq(abi.decode(results[0], (uint256)), 11);
        assertEq(abi.decode(results[1], (uint256)), 42);
    }
}
