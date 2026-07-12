// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PiggyBank} from "./PiggyBank.sol";

/// @title PiggyBankFactory
/// @notice Stamps out ERC-1167 minimal proxy clones of one canonical
///         PiggyBank. Each clone is a 45-byte contract that delegatecalls
///         every call to the implementation, so deploying one costs a tiny
///         fraction of `new PiggyBank()` while behaving identically (with
///         its own storage).
///
/// @dev The 45 bytes, byte by byte (this is the whole clone contract):
///
///        363d3d373d3d3d363d73 <20-byte implementation> 5af43d82803e903d91602b57fd5bf3
///
///      1. `36 3d 3d 37`  CALLDATASIZE PUSH0 PUSH0 CALLDATACOPY — copy the
///         entire calldata to memory position 0.
///      2. `3d 3d 3d 36`  three PUSH0s and CALLDATASIZE — lay out the
///         delegatecall arguments: retOffset 0, retSize 0, argOffset 0,
///         argSize = calldatasize.
///      3. `3d 73 <impl>` PUSH0, PUSH20 implementation — the target address
///         is a literal *baked into the bytecode*, which is exactly why a
///         clone can never be upgraded: re-pointing it would mean rewriting
///         deployed code.
///      4. `5a f4`        GAS DELEGATECALL — run the implementation's code
///         against the clone's own storage/balance/address.
///      5. `3d 82 80 3e`  RETURNDATASIZE ... RETURNDATACOPY — copy whatever
///         the implementation returned back to memory 0.
///      6. `90 3d 91 60 2b 57 fd 5b f3` — if the delegatecall failed, REVERT
///         with that data; otherwise RETURN it (JUMPI to the JUMPDEST at
///         offset 0x2b picks the branch).
///
///      The cost triangle this completes (see the beacon fleet for the
///      middle corner): full `new` deploy is the most expensive but has zero
///      per-call overhead; a BeaconProxy deploy is cheaper and one beacon tx
///      re-points every instance, but each call pays an extra beacon SLOAD +
///      staticcall; a clone is by far the cheapest to deploy and pays only
///      one delegatecall hop per call — in exchange for being frozen to its
///      implementation forever.
contract PiggyBankFactory {
    using Clones for address;

    /// @notice The canonical PiggyBank every clone delegatecalls into.
    ///         Deployed by the factory itself so it is guaranteed to have
    ///         its initializers disabled.
    address public immutable implementation;

    address[] private _banks;

    event BankCreated(address indexed bank, address indexed creator, uint256 unlockTime, bytes32 salt);

    constructor() {
        implementation = address(new PiggyBank());
    }

    /// @notice Deploy a clone at a deterministic address and initialize it
    ///         atomically with the caller as owner — no window where an
    ///         uninitialized clone sits waiting for someone else to claim it.
    /// @dev The CREATE2 salt is namespaced with `msg.sender`, so the address
    ///      you predict for *your* salt is yours alone: nobody can grief you
    ///      by deploying to it first, and two creators may reuse the same
    ///      salt without colliding. The same creator reusing a salt reverts
    ///      (CREATE2 refuses to redeploy to an occupied address).
    function createBank(uint256 unlockTime, bytes32 salt) external returns (address bank) {
        bank = implementation.cloneDeterministic(_namespacedSalt(msg.sender, salt));
        PiggyBank(payable(bank)).initialize(msg.sender, unlockTime);
        _banks.push(bank);
        emit BankCreated(bank, msg.sender, unlockTime, salt);
    }

    /// @notice The address `createBank` will deploy to for a given creator
    ///         and salt — knowable (and fundable) before the bank exists.
    function predictBankAddress(address creator, bytes32 salt) external view returns (address) {
        return implementation.predictDeterministicAddress(_namespacedSalt(creator, salt), address(this));
    }

    /// @notice Every bank ever created by this factory, in creation order.
    function allBanks() external view returns (address[] memory) {
        return _banks;
    }

    function _namespacedSalt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(creator, salt));
    }
}
