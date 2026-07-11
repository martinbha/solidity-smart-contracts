// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title MultisigWallet
/// @notice m-of-n wallet executing arbitrary calls once at least `threshold`
///         owners have approved via off-chain EIP-712 signatures. Owners sign
///         a typed `Transaction` payload; anyone may submit the signed bundle
///         to `execute` in a single transaction — no on-chain confirm loop.
///
/// @dev Signature handling notes:
///
///      - Signatures must be sorted by strictly ascending signer address.
///        This makes duplicate-signer detection O(1) per signature (each
///        recovered address must exceed the previous one) — the same scheme
///        Safe uses.
///      - OZ `ECDSA.recover` rejects malleable (high-s) signatures and a
///        recovered zero address, closing the classic `ecrecover` pitfalls.
///      - The EIP-712 domain separator binds signatures to this chain id and
///        this wallet address, so a bundle signed for one wallet can never be
///        replayed on another wallet or another chain.
///      - The nonce binds a bundle to a single execution slot. It is bumped
///        before the external call; if the inner call reverts, `execute`
///        bubbles the revert, which also rolls back the bump — the bundle
///        stays valid and may be resubmitted once conditions change. Consuming
///        the nonce for a failed call would require swallowing the failure,
///        which silently burns approvals; bubbling was chosen instead.
///      - No separate reentrancy guard is needed: the nonce is bumped before
///        the external call, so a reentrant `execute` from the inner call
///        must present `threshold` fresh signatures over the *next* nonce —
///        which is just a legitimate, fully approved execution.
///
///      Owner-set changes go through the wallet's own execution path: the
///      admin functions are `onlySelf`, so they require the same m-of-n
///      approval as any other call.
contract MultisigWallet is EIP712 {
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        uint256 nonce;
    }

    bytes32 public constant TRANSACTION_TYPEHASH =
        keccak256("Transaction(address to,uint256 value,bytes data,uint256 nonce)");

    /// @notice True for every current owner.
    mapping(address => bool) public isOwner;
    /// @notice Number of current owners (`n`).
    uint256 public ownerCount;
    /// @notice Signatures required to execute (`m`).
    uint256 public threshold;
    /// @notice Nonce of the next executable transaction.
    uint256 public nonce;

    event Deposited(address indexed sender, uint256 amount);
    event Executed(uint256 indexed nonce, address indexed to, uint256 value, bytes data);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 threshold);

    error NotSelf();
    error InvalidTarget();
    error InvalidOwner(address owner);
    error DuplicateOwner(address owner);
    error InvalidThreshold(uint256 threshold, uint256 ownerCount);
    error WrongNonce(uint256 expected, uint256 provided);
    error NotEnoughSignatures(uint256 required, uint256 provided);
    error InvalidSigner(address signer);
    error UnsortedSigners();

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(address[] memory owners_, uint256 threshold_) EIP712("MultisigWallet", "1") {
        if (threshold_ == 0 || threshold_ > owners_.length) {
            revert InvalidThreshold(threshold_, owners_.length);
        }
        for (uint256 i = 0; i < owners_.length; i++) {
            _addOwner(owners_[i]);
        }
        threshold = threshold_;
        emit ThresholdChanged(threshold_);
    }

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice EIP-712 digest owners must sign to approve `txn`.
    function txHash(Transaction calldata txn) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(TRANSACTION_TYPEHASH, txn.to, txn.value, keccak256(txn.data), txn.nonce))
        );
    }

    /// @notice Executes `txn` given at least `threshold` owner signatures over
    ///         its EIP-712 digest, sorted by ascending signer address.
    /// @dev Only the first `threshold` signatures are verified; extras are
    ///      ignored. Bumps the nonce before the external call and bubbles the
    ///      inner revert reason on failure (rolling the bump back with it).
    function execute(Transaction calldata txn, bytes[] calldata signatures)
        external
        returns (bytes memory)
    {
        // A zero target is never useful (a call to it succeeds and burns the
        // value); reject it so a payload with an unset `to` cannot pass.
        if (txn.to == address(0)) revert InvalidTarget();
        if (txn.nonce != nonce) revert WrongNonce(nonce, txn.nonce);
        uint256 required = threshold;
        if (signatures.length < required) {
            revert NotEnoughSignatures(required, signatures.length);
        }

        bytes32 digest = txHash(txn);
        address last = address(0);
        for (uint256 i = 0; i < required; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!isOwner[signer]) revert InvalidSigner(signer);
            if (signer <= last) revert UnsortedSigners();
            last = signer;
        }

        nonce = txn.nonce + 1;

        (bool ok, bytes memory result) = txn.to.call{value: txn.value}(txn.data);
        if (!ok) {
            // Bubble the inner revert reason as-is.
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }

        emit Executed(txn.nonce, txn.to, txn.value, txn.data);
        return result;
    }

    /// @notice Adds an owner. Callable only through `execute`.
    function addOwner(address owner) external onlySelf {
        _addOwner(owner);
    }

    /// @notice Removes an owner. Callable only through `execute`. Reverts if
    ///         removal would leave fewer owners than the threshold requires.
    function removeOwner(address owner) external onlySelf {
        if (!isOwner[owner]) revert InvalidOwner(owner);
        if (ownerCount - 1 < threshold) {
            revert InvalidThreshold(threshold, ownerCount - 1);
        }
        isOwner[owner] = false;
        ownerCount--;
        emit OwnerRemoved(owner);
    }

    /// @notice Sets a new signature threshold. Callable only through `execute`.
    function changeThreshold(uint256 newThreshold) external onlySelf {
        if (newThreshold == 0 || newThreshold > ownerCount) {
            revert InvalidThreshold(newThreshold, ownerCount);
        }
        threshold = newThreshold;
        emit ThresholdChanged(newThreshold);
    }

    function _addOwner(address owner) internal {
        if (owner == address(0)) revert InvalidOwner(owner);
        if (isOwner[owner]) revert DuplicateOwner(owner);
        isOwner[owner] = true;
        ownerCount++;
        emit OwnerAdded(owner);
    }
}
