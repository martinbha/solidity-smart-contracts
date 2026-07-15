// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS} from "account-abstraction/core/Helpers.sol";

/// @title SmartAccount
/// @notice A minimal ERC-4337 smart-contract account: a single ECDSA owner,
///         but the account — not the protocol — decides what a valid
///         signature is. Users never send transactions themselves; they sign
///         `UserOperation`s that a bundler submits to the singleton
///         `EntryPoint`, which calls back into `validateUserOp` here.
///
/// @dev The 4337 control flow this account participates in:
///
///      1. `EntryPoint.handleOps` receives a bundle of signed UserOps.
///      2. For each, it calls `validateUserOp` (inherited from `BaseAccount`):
///         the account checks the signature and pays its *prefund* — the ETH
///         the EntryPoint fronts for gas, unless a paymaster covers it.
///      3. Only after every op in the bundle validates does the EntryPoint
///         call the account's execution (`execute` / `executeBatch`).
///
///      Validation and execution are deliberately split: during validation
///      the EntryPoint restricts what storage an account may touch (ERC-7562)
///      so a bundler can trust a passing validation off-chain without the op
///      later reverting at execution and sticking the bundler with the gas.
///
///      Signature scheme: `_validateSignature` recovers over the raw
///      `userOpHash` (which the EntryPoint already builds as an EIP-712 typed
///      digest binding the op to this EntryPoint and chain id), so a plain
///      `vm.sign`/`eth_sign` over that hash authorizes the op. Swapping this
///      one method for an EIP-1271 call, a multisig, or a passkey verifier is
///      exactly the programmability 4337 exists to give — the rest of the
///      account is unchanged. Only the owner or the EntryPoint may drive
///      execution (`_requireForExecute`); everyone else is rejected.
///
///      `owner` and `_entryPoint` are immutable and set at construction, so
///      the CREATE2 counterfactual address the factory predicts is a pure
///      function of (owner, entryPoint, salt) — no initializer, no proxy.
contract SmartAccount is BaseAccount {
    address public immutable owner;
    IEntryPoint private immutable _entryPoint;

    constructor(IEntryPoint entryPoint_, address owner_) {
        _entryPoint = entryPoint_;
        owner = owner_;
    }

    /// @notice Accept plain ETH transfers (e.g. to fund the account's own
    ///         prefund deposit or receive value).
    receive() external payable {}

    /// @inheritdoc BaseAccount
    function entryPoint() public view override returns (IEntryPoint) {
        return _entryPoint;
    }

    /// @dev The account's programmable authorization rule. Recovers the signer
    ///      from the EntryPoint-supplied `userOpHash` and accepts the op only
    ///      if it is the owner. Returns the packed validation code the
    ///      EntryPoint expects — never reverts on a bad signature, so a bundle
    ///      can cleanly drop the offending op instead of failing wholesale.
    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        view
        override
        returns (uint256 validationData)
    {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(userOpHash, userOp.signature);
        if (err != ECDSA.RecoverError.NoError || recovered != owner) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }

    /// @dev Gate on `execute`/`executeBatch`: the EntryPoint (driving a
    ///      validated op) or the owner (calling directly) may execute; nobody
    ///      else. Overrides BaseAccount's EntryPoint-only default to also
    ///      allow the owner.
    function _requireForExecute() internal view override {
        require(msg.sender == address(entryPoint()) || msg.sender == owner, "SmartAccount: not owner or EntryPoint");
    }
}
