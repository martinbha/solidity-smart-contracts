// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title SignerMultisig
/// @notice An m-of-n multisig that signs *as a contract* via EIP-1271. Like
///         the issue #6 wallet it can execute calls once enough owners agree,
///         but it adds the thing `ecrecover` can never give a contract: the
///         ability to *be a signer*. Through `isValidSignature` it answers
///         "did enough owners sign this hash?" for any EIP-1271-aware
///         consumer, so the multisig can approve a Permit, authorize a
///         marketplace order, or log into a dapp — as a first-class signer.
///
/// @dev One verification primitive, two surfaces:
///
///      - `isValidSignature(hash, sig)` is the EIP-1271 view a consumer
///        staticcalls. It returns the magic value iff `threshold` owners
///        signed `hash`.
///      - `execute(...)` reuses that exact check to authorize an on-chain
///        call, binding it to this wallet's EIP-712 domain and a nonce so an
///        execution bundle can't be replayed. This is what lets the multisig
///        act as an order maker — e.g. `approve` a settlement venue — not just
///        sign.
///
///      The signature encoding mirrors the issue #6 multisig exactly:
///
///      - `signature` is owner signatures concatenated, 65 bytes each, ordered
///        by strictly ascending signer address. Ascending order makes
///        duplicate-signer detection O(1) — each recovered address must beat
///        the previous — the scheme Safe uses.
///      - Only the first `threshold` signatures are inspected; extras are
///        ignored, so a caller may append more without harm.
///      - `ECDSA.tryRecover` rejects malleable (high-s) signatures and never
///        reverts, so a malformed blob makes `isValidSignature` return the
///        failure value cleanly — a 1271 signer must not revert a consumer's
///        `staticcall`.
///
///      For an external consumer the signed `hash` carries its own domain and
///      replay protection (e.g. an OrderBook's EIP-712 order digest); this
///      contract adds none of its own to that path, exactly as an EOA signer
///      wouldn't. The `execute` path is the one place the wallet imposes its
///      own domain + nonce, because there it is the authorizer, not a witness.
///
///      The owner set is immutable — fixed at construction, never governed.
contract SignerMultisig is IERC1271, EIP712 {
    /// @notice EIP-1271 "valid" sentinel: `IERC1271.isValidSignature.selector`.
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;
    /// @notice Returned for any signature that does not meet the threshold.
    bytes4 internal constant INVALID = 0xffffffff;

    bytes32 public constant EXECUTE_TYPEHASH =
        keccak256("Execute(address target,uint256 value,bytes data,uint256 nonce)");

    /// @notice True for every owner.
    mapping(address => bool) public isOwner;
    /// @notice Number of owners (`n`).
    uint256 public immutable ownerCount;
    /// @notice Signatures required for a valid bundle (`m`).
    uint256 public immutable threshold;
    /// @notice Nonce of the next executable call.
    uint256 public nonce;

    event Executed(uint256 indexed nonce, address indexed target, uint256 value, bytes data);

    error InvalidThreshold(uint256 threshold, uint256 ownerCount);
    error InvalidOwner(address owner);
    error DuplicateOwner(address owner);
    error NotEnoughSignatures();

    constructor(address[] memory owners, uint256 threshold_) EIP712("SignerMultisig", "1") {
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
        return _thresholdSigned(hash, signature) ? MAGIC_VALUE : INVALID;
    }

    /// @notice EIP-712 digest owners must sign to authorize the call
    ///         `execute(target, value, data)` at `nonce_`.
    function hashExecute(address target, uint256 value, bytes calldata data, uint256 nonce_)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(EXECUTE_TYPEHASH, target, value, keccak256(data), nonce_)));
    }

    /// @notice Executes `target.call{value}(data)` once `threshold` owners have
    ///         signed the call's EIP-712 digest. Lets the multisig act, not
    ///         just witness — e.g. approve a settlement venue before its orders
    ///         can be filled.
    /// @dev Binds the digest to this wallet's domain and current nonce, then
    ///      reuses the same `isValidSignature` check. The nonce is bumped
    ///      before the call and the inner revert reason bubbles on failure,
    ///      rolling the bump back with it (so a failed call's bundle stays
    ///      valid) — the issue #6 semantics.
    function execute(address target, uint256 value, bytes calldata data, bytes calldata signature)
        external
        returns (bytes memory)
    {
        bytes32 digest = hashExecute(target, value, data, nonce);
        if (!_thresholdSigned(digest, signature)) revert NotEnoughSignatures();

        uint256 executedNonce = nonce;
        nonce = executedNonce + 1;

        (bool ok, bytes memory result) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }

        emit Executed(executedNonce, target, value, data);
        return result;
    }

    /// @dev True iff the first `threshold` 65-byte signatures in `signature`
    ///      are owners' signatures over `hash`, strictly ascending by address.
    function _thresholdSigned(bytes32 hash, bytes calldata signature) internal view returns (bool) {
        uint256 required = threshold;
        // Need at least `required` whole 65-byte signatures to possibly pass.
        if (signature.length < required * 65) return false;

        address last = address(0);
        for (uint256 i = 0; i < required; i++) {
            bytes calldata sig = signature[i * 65:i * 65 + 65];
            bytes32 r = bytes32(sig[0:32]);
            bytes32 s = bytes32(sig[32:64]);
            uint8 v = uint8(sig[64]);

            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, v, r, s);
            if (err != ECDSA.RecoverError.NoError) return false;
            if (!isOwner[signer]) return false;
            // Strictly ascending: also rejects a repeated signer.
            if (signer <= last) return false;
            last = signer;
        }
        return true;
    }
}
