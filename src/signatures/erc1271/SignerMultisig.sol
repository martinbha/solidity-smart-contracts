// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title SignerMultisig
/// @notice An m-of-n multisig that signs *as a contract* via EIP-1271. Where
///         the issue #6 wallet executes transactions, this one only answers a
///         single question — "did enough owners sign this hash?" — through
///         `isValidSignature`. That makes the contract a first-class signer
///         anywhere an EIP-1271-aware consumer looks: it can approve a Permit,
///         authorize a marketplace order, or log into a dapp, none of which
///         `ecrecover` alone could ever let a contract do.
///
/// @dev The verification mirrors the issue #6 multisig exactly, so the same
///      mental model carries over:
///
///      - `signature` is owner signatures concatenated, 65 bytes each, ordered
///        by strictly ascending signer address. Ascending order makes
///        duplicate-signer detection O(1) — each recovered address must beat
///        the previous — the scheme Safe uses.
///      - Only the first `threshold` signatures are inspected; extras beyond
///        the threshold are ignored, so a caller may append more without harm.
///      - `ECDSA.tryRecover` rejects malleable (high-s) signatures and never
///        reverts, so a malformed blob returns the failure magic value cleanly
///        rather than bubbling — a 1271 signer must not revert a consumer's
///        `staticcall`.
///      - The signed `hash` is whatever the consumer computed (e.g. an
///        OrderBook's EIP-712 order digest). This contract adds no domain of
///        its own: domain-binding and replay protection live in that digest,
///        exactly as they do for an EOA signer.
///
///      Unlike issue #6 this is a pure signer with no execution path, so the
///      owner set is immutable — fixed at construction, never governed.
contract SignerMultisig is IERC1271 {
    /// @notice EIP-1271 "valid" sentinel: `IERC1271.isValidSignature.selector`.
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;
    /// @notice Returned for any signature that does not meet the threshold.
    bytes4 internal constant INVALID = 0xffffffff;

    /// @notice True for every owner.
    mapping(address => bool) public isOwner;
    /// @notice Number of owners (`n`).
    uint256 public immutable ownerCount;
    /// @notice Signatures required for a valid bundle (`m`).
    uint256 public immutable threshold;

    error InvalidThreshold(uint256 threshold, uint256 ownerCount);
    error InvalidOwner(address owner);
    error DuplicateOwner(address owner);

    constructor(address[] memory owners, uint256 threshold_) {
        if (threshold_ == 0 || threshold_ > owners.length) {
            revert InvalidThreshold(threshold_, owners.length);
        }
        for (uint256 i = 0; i < owners.length; i++) {
            address owner = owners[i];
            if (owner == address(0)) revert InvalidOwner(owner);
            if (isOwner[owner]) revert DuplicateOwner(owner);
            isOwner[owner] = true;
        }
        ownerCount = owners.length;
        threshold = threshold_;
    }

    /// @notice Accept ETH so the multisig can be paid as an order maker (or
    ///         otherwise hold a balance while acting purely as a signer).
    receive() external payable {}

    /// @inheritdoc IERC1271
    /// @notice Returns the EIP-1271 magic value iff at least `threshold` owners
    ///         signed `hash`, with their 65-byte signatures concatenated in
    ///         strictly ascending signer-address order; otherwise `0xffffffff`.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        uint256 required = threshold;
        // Need at least `required` whole 65-byte signatures to possibly pass.
        if (signature.length < required * 65) return INVALID;

        address last = address(0);
        for (uint256 i = 0; i < required; i++) {
            bytes calldata sig = signature[i * 65:i * 65 + 65];
            bytes32 r = bytes32(sig[0:32]);
            bytes32 s = bytes32(sig[32:64]);
            uint8 v = uint8(sig[64]);

            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, v, r, s);
            if (err != ECDSA.RecoverError.NoError) return INVALID;
            if (!isOwner[signer]) return INVALID;
            // Strictly ascending: also rejects a repeated signer.
            if (signer <= last) return INVALID;
            last = signer;
        }
        return MAGIC_VALUE;
    }
}
