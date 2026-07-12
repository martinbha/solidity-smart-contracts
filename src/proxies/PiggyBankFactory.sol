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
///      1. `36 3d 3d 37`  CALLDATASIZE RETURNDATASIZE RETURNDATASIZE
///         CALLDATACOPY — copy the full calldata to memory 0. The famous
///         trick: 0x3d is RETURNDATASIZE, which reads as zero before any
///         call has happened. EIP-1167 predates PUSH0 (0x5f), and
///         RETURNDATASIZE was the cheapest zero available.
///      2. `3d 3d 3d 36 3d`  five more stack slots for the delegatecall: a
///         spare zero the epilogue reuses as its memory offset, the return
///         area (offset 0, size 0), CALLDATASIZE as the argument length,
///         and a final zero as the argument offset.
///      3. `73 <impl>`    PUSH20 implementation — the target address is a
///         literal *baked into the bytecode*, which is exactly why a clone
///         can never be upgraded: re-pointing it would mean rewriting
///         deployed code.
///      4. `5a f4`        GAS DELEGATECALL — run the implementation's code
///         against the clone's own storage/balance/address.
///      5. `3d 82 80 3e`  RETURNDATASIZE DUP3 DUP1 RETURNDATACOPY — now 3d
///         reads the real return size; copy the result back to memory 0.
///      6. `90 3d 91 60 2b 57 fd 5b f3` — shuffle the success flag up and
///         JUMPI to the JUMPDEST at offset 0x2b: RETURN the data on
///         success, fall through to REVERT with it on failure.
///
///      The cost triangle this completes (src/upgradeable/beacon is the
///      middle corner): full `new` deploy is the most expensive but has zero
///      per-call overhead; a BeaconProxy deploy is cheaper and one beacon tx
///      re-points every instance, but each call pays a delegatecall hop plus
///      a staticcall to the beacon to resolve the implementation; a clone is
///      by far the cheapest to deploy and pays only the delegatecall hop —
///      in exchange for being frozen to its implementation forever. Measured
///      numbers live in test/proxies/PiggyBankClones.t.sol (run with -vv).
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
    /// @dev Fund a predicted address with care: ETH parked there only
    ///      becomes withdrawable once the creator actually creates the bank
    ///      (the sweep then includes it). If the bank is never created,
    ///      nothing can ever move the funds.
    function predictBankAddress(address creator, bytes32 salt) external view returns (address) {
        return implementation.predictDeterministicAddress(_namespacedSalt(creator, salt), address(this));
    }

    /// @notice Every bank ever created by this factory, in creation order.
    /// @dev Unbounded and returned as one array copy: a convenience for
    ///      off-chain indexers. On-chain callers should not iterate it —
    ///      the copy grows (and costs more) with every bank ever created.
    function allBanks() external view returns (address[] memory) {
        return _banks;
    }

    function _namespacedSalt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
