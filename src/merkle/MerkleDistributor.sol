// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title MerkleDistributor
/// @notice Distributes tokens to an arbitrarily large recipient set while
///         storing only 32 bytes on-chain: the root of a Merkle tree built
///         off-chain (see script/merkle/GenerateMerkleTree.s.sol). Recipients
///         prove membership with a short proof when they claim.
///
///         Anyone may submit claim() on a recipient's behalf — tokens always
///         go to the proven account, so relayers can pay gas for users.
///         claimTo() additionally lets a recipient redirect tokens to another
///         address by signing an EIP-712 authorization off-chain.
contract MerkleDistributor is Ownable, EIP712 {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    bytes32 public immutable merkleRoot;
    /// @notice Timestamp after which claims close and the owner may clawback.
    uint256 public immutable claimDeadline;

    /// @dev One storage word covers 256 claims — packed bitmap bookkeeping.
    mapping(uint256 => uint256) private _claimedBitMap;

    bytes32 public constant CLAIM_TO_TYPEHASH =
        keccak256("ClaimTo(uint256 index,address account,uint256 amount,address recipient)");

    event Claimed(uint256 indexed index, address indexed account, address recipient, uint256 amount);
    event Clawback(address indexed to, uint256 amount);

    error AlreadyClaimed(uint256 index);
    error InvalidProof();
    error InvalidSignature();
    error ClaimWindowClosed();
    error ClaimWindowStillOpen();

    constructor(IERC20 token_, bytes32 merkleRoot_, uint256 claimDeadline_, address initialOwner)
        Ownable(initialOwner)
        EIP712("MerkleDistributor", "1")
    {
        token = token_;
        merkleRoot = merkleRoot_;
        claimDeadline = claimDeadline_;
    }

    /// @notice Claim `amount` tokens for `account`. Callable by anyone (e.g. a
    ///         gas-paying relayer); tokens go to `account` regardless of sender.
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
    {
        _claim(index, account, amount, account, proof);
    }

    /// @notice Claim on behalf of `account` but send the tokens to `recipient`,
    ///         authorized by `account`'s EIP-712 signature over the full claim.
    ///         Replay-safe without nonces: the claim index can only be spent once.
    function claimTo(
        uint256 index,
        address account,
        uint256 amount,
        address recipient,
        bytes32[] calldata proof,
        bytes calldata signature
    ) external {
        bytes32 digest = claimToDigest(index, account, amount, recipient);
        if (ECDSA.recover(digest, signature) != account) revert InvalidSignature();
        _claim(index, account, amount, recipient, proof);
    }

    /// @notice EIP-712 digest a recipient signs to authorize claimTo. Exposed
    ///         so off-chain tooling and tests build byte-identical digests.
    function claimToDigest(uint256 index, address account, uint256 amount, address recipient)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(CLAIM_TO_TYPEHASH, index, account, amount, recipient))
        );
    }

    /// @notice Reclaim whatever was never claimed, only after the window closes.
    function clawback(address to) external onlyOwner {
        // Deadline granularity is days; ±15s of proposer timestamp drift is harmless.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= claimDeadline) revert ClaimWindowStillOpen();
        uint256 remaining = token.balanceOf(address(this));
        token.safeTransfer(to, remaining);
        emit Clawback(to, remaining);
    }

    function isClaimed(uint256 index) public view returns (bool) {
        uint256 word = _claimedBitMap[index / 256];
        // forge-lint: disable-next-line(incorrect-shift)
        return word & (1 << (index % 256)) != 0; // intentional bit-mask shift
    }

    function _claim(
        uint256 index,
        address account,
        uint256 amount,
        address recipient,
        bytes32[] calldata proof
    ) private {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > claimDeadline) revert ClaimWindowClosed();
        if (isClaimed(index)) revert AlreadyClaimed(index);

        // Double-hashed leaf prevents second-preimage attacks: a 64-byte
        // internal node can never collide with a leaf encoding.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        // forge-lint: disable-next-line(incorrect-shift)
        _claimedBitMap[index / 256] |= 1 << (index % 256); // intentional bit-mask shift
        token.safeTransfer(recipient, amount);
        emit Claimed(index, account, recipient, amount);
    }
}
