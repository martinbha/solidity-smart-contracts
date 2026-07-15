// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title OrderBook
/// @notice A minimal signed-order settlement venue that accepts EOA *and*
///         contract makers transparently. A maker signs an `Order` off-chain;
///         a taker submits it with the maker's signature and the ETH price,
///         and the book settles: ETH to the maker, tokens to the taker.
///
/// @dev The whole point is the one verification call:
///
///          SignatureChecker.isValidSignatureNow(order.maker, digest, sig)
///
///      which branches on `order.maker.code.length`. An EOA maker is checked
///      with `ecrecover`; a contract maker is checked by staticcalling its
///      EIP-1271 `isValidSignature`. The book never needs to know which kind
///      the maker is — a `SignerMultisig`, a 4337 account, or a plain wallet
///      all fill the same way. A contract that doesn't implement 1271 (no
///      such function) makes the staticcall return nothing, which the checker
///      reads as "invalid" rather than reverting, so `fillOrder` fails with a
///      clean `BadSignature` instead of a bubbled low-level revert.
///
///      Replay and domain binding are the signer's usual concerns, handled
///      here on the consumer side:
///
///      - The digest is EIP-712 over this book's domain (chain id + this
///        address), so an order signed for this book can't be replayed on
///        another book or chain.
///      - Each `(maker, nonce)` fills at most once; the nonce is consumed
///        before any external call, closing reentrant refills.
///
///      Settlement assumes the maker has approved this book to move `amount`
///      of `token` (an `approve` for an EOA, or a governed approval for a
///      contract maker). The taker must send exactly `price` wei.
contract OrderBook is EIP712 {
    using SafeERC20 for IERC20;

    struct Order {
        address maker;
        address token;
        uint256 amount;
        uint256 price;
        uint256 nonce;
    }

    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address maker,address token,uint256 amount,uint256 price,uint256 nonce)");

    /// @notice True once `(maker, nonce)` has been filled.
    mapping(address => mapping(uint256 => bool)) public filled;

    event OrderFilled(
        address indexed maker,
        address indexed taker,
        address indexed token,
        uint256 amount,
        uint256 price,
        uint256 nonce
    );

    error OrderAlreadyFilled(address maker, uint256 nonce);
    error BadSignature();
    error WrongPayment(uint256 expected, uint256 provided);

    constructor() EIP712("OrderBook", "1") {}

    /// @notice The EIP-712 digest a maker signs to authorize `order`.
    function hashOrder(Order calldata order) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(ORDER_TYPEHASH, order.maker, order.token, order.amount, order.price, order.nonce))
        );
    }

    /// @notice Fills `order` given the maker's signature over its digest.
    ///         Sends `order.price` wei to the maker and pulls `order.amount`
    ///         of `order.token` from the maker to the taker.
    /// @dev `makerSignature` is passed straight to `SignatureChecker`, so it
    ///      is either a 65-byte ECDSA signature (EOA maker) or whatever blob
    ///      the maker's EIP-1271 verifier expects (e.g. concatenated owner
    ///      signatures for a `SignerMultisig`).
    function fillOrder(Order calldata order, bytes calldata makerSignature) external payable {
        if (filled[order.maker][order.nonce]) {
            revert OrderAlreadyFilled(order.maker, order.nonce);
        }
        if (msg.value != order.price) revert WrongPayment(order.price, msg.value);
        if (!SignatureChecker.isValidSignatureNow(order.maker, hashOrder(order), makerSignature)) {
            revert BadSignature();
        }

        // Consume the nonce before any external call (reentrancy-safe).
        filled[order.maker][order.nonce] = true;

        // Settle: ETH to the maker, tokens from the maker to the taker.
        (bool paid,) = order.maker.call{value: msg.value}("");
        if (!paid) revert WrongPayment(order.price, msg.value);
        IERC20(order.token).safeTransferFrom(order.maker, msg.sender, order.amount);

        emit OrderFilled(order.maker, msg.sender, order.token, order.amount, order.price, order.nonce);
    }
}
