// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {SmartAccount} from "./SmartAccount.sol";

/// @title SmartAccountFactory
/// @notice Deploys `SmartAccount`s at deterministic CREATE2 addresses, so an
///         account's address is known *before* it exists on chain. That
///         counterfactual address is what makes 4337 onboarding seamless: a
///         user can be handed their account address, receive funds at it, and
///         the account is only actually deployed when their first
///         `UserOperation` runs — the EntryPoint runs the op's `initCode`
///         (this factory's `createAccount` call) and the account is created
///         in the same transaction that first uses it.
///
/// @dev `createAccount` is idempotent: if the account already exists at its
///      predicted address it returns it instead of redeploying, so an op
///      whose `initCode` points here is safe even if the account was funded
///      or deployed by some earlier path. `getAddress` recomputes the same
///      CREATE2 address off-chain from (owner, salt).
///
///      The canonical eth-infinitism factory restricts `createAccount` to the
///      EntryPoint's `SenderCreator` (a griefing guard: it stops a bundler
///      from being tricked into paying to deploy an account whose init then
///      reverts). This teaching factory leaves it open so tests and scripts
///      can deploy directly as well as through `initCode`; the tradeoff is
///      noted here rather than hidden.
contract SmartAccountFactory {
    IEntryPoint public immutable entryPoint;

    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    constructor(IEntryPoint entryPoint_) {
        entryPoint = entryPoint_;
    }

    /// @notice Deploys the account for `owner`/`salt`, or returns the existing
    ///         one if already deployed.
    function createAccount(address owner, uint256 salt) external returns (SmartAccount account) {
        address predicted = getAddress(owner, salt);
        if (predicted.code.length > 0) {
            return SmartAccount(payable(predicted));
        }
        account = new SmartAccount{salt: bytes32(salt)}(entryPoint, owner);
        emit AccountCreated(address(account), owner, salt);
    }

    /// @notice The CREATE2 address `createAccount(owner, salt)` will deploy to.
    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Create2.computeAddress(
            bytes32(salt), keccak256(abi.encodePacked(type(SmartAccount).creationCode, abi.encode(entryPoint, owner)))
        );
    }
}
