// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BasePaymaster} from "account-abstraction/core/BasePaymaster.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SmartAccount} from "./SmartAccount.sol";

/// @title SponsorPaymaster
/// @notice A paymaster that pays gas for UserOperations — but only ones that
///         call an allowlisted app. This is the "gasless dApp" model: the app
///         operator stakes an ETH deposit in the EntryPoint and agrees to
///         cover gas for interactions with its own contracts, so a user with
///         zero ETH can still transact.
///
/// @dev The EntryPoint calls `validatePaymasterUserOp` during the validation
///      phase; a paymaster that returns success there is on the hook for the
///      op's gas (the EntryPoint debits its deposit at the end). This one
///      agrees iff every call the op makes targets an allowlisted address:
///
///      - It inspects the account's `callData` — the `execute` /
///        `executeBatch` the account will run — and pulls out the target(s).
///        Sponsoring is about *what the op does*, so the decision is made on
///        the call targets, not on who signed.
///      - It returns an empty context and `0` validation data (valid, no time
///        bounds). Empty context means no `postOp` bookkeeping is needed — it
///        sponsors flat, without settling a per-op charge afterward.
///      - Reading only its own `allowed` mapping (keyed by an address already
///        in the op) keeps it within the storage-access rules the EntryPoint
///        enforces on paymasters during validation.
///
///      An unrecognized selector or any non-allowlisted target reverts, which
///      the EntryPoint surfaces as a rejected op — the paymaster never pays
///      for something outside the set its operator opted into.
contract SponsorPaymaster is BasePaymaster {
    /// @notice Apps this paymaster will sponsor calls to.
    mapping(address => bool) public allowed;

    event TargetAllowed(address indexed target, bool allowed);

    error TargetNotAllowed(address target);
    error UnsupportedSelector(bytes4 selector);

    constructor(IEntryPoint entryPoint_) BasePaymaster(entryPoint_) {}

    /// @notice Allow or disallow sponsoring calls to `target`. Owner only.
    function setAllowed(address target, bool value) external onlyOwner {
        allowed[target] = value;
        emit TargetAllowed(target, value);
    }

    /// @dev Agrees to sponsor iff every target the op will call is allowlisted.
    ///      Reverts otherwise, which the EntryPoint turns into a rejected op.
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256)
        internal
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        bytes calldata callData = userOp.callData;
        // A call shorter than a selector (e.g. a deploy-only op with empty
        // callData) is nothing this paymaster sponsors — reject it cleanly
        // rather than letting the slice below panic out of bounds.
        if (callData.length < 4) revert UnsupportedSelector(bytes4(0));
        bytes4 selector = bytes4(callData[:4]);

        if (selector == BaseAccount.execute.selector) {
            // execute(address target, uint256 value, bytes data) — decode only
            // the leading target word; the value and (dynamic) data payload
            // are irrelevant to the sponsoring decision and copying them in
            // during gas-restricted validation is wasted work.
            address target = abi.decode(callData[4:], (address));
            _requireAllowed(target);
        } else if (selector == BaseAccount.executeBatch.selector) {
            // executeBatch(Call[] calls) — every leg must be allowlisted, so
            // a batch can't smuggle an unsponsored call in beside a valid one.
            BaseAccount.Call[] memory calls = abi.decode(callData[4:], (BaseAccount.Call[]));
            for (uint256 i = 0; i < calls.length; i++) {
                _requireAllowed(calls[i].target);
            }
        } else {
            revert UnsupportedSelector(selector);
        }

        return ("", 0);
    }

    function _requireAllowed(address target) internal view {
        if (!allowed[target]) revert TargetNotAllowed(target);
    }
}
