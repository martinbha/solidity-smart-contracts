// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title MinimalForwarder
/// @notice ERC-2771 forwarder: a user signs a `ForwardRequest` off-chain and
///         any relayer submits it, paying the gas. The forwarder verifies the
///         signature and nonce, then calls the target with the user's address
///         appended to the calldata — an ERC-2771-aware target (one that
///         trusts this forwarder) reads that suffix as the real sender, so
///         "who pays gas" (the relayer) is fully separated from "who
///         authorized the action" (the signer).
///
/// @dev Modeled on OpenZeppelin v4's MinimalForwarder (removed in OZ 5.x in
///      favor of the production-grade `ERC2771Forwarder`), kept minimal here
///      so every moving part is visible:
///
///      - Requests are EIP-712 typed data under this forwarder's domain, so
///        a request signed for one forwarder/chain cannot be replayed on
///        another.
///      - One sequential nonce per signer gives replay protection. The nonce
///        is consumed even if the inner call reverts — unlike the multisig's
///        resubmittable bundles, a relayed request is a one-shot: the signer
///        cannot know when (or how many times) a relayer will retry, so a
///        failed attempt must not leave a live signature behind.
///      - The forwarder itself is trustless: it can only execute exactly what
///        was signed. All the trust sits on the *target's* side, in its
///        choice of trusted forwarder (see GaslessVault).
contract MinimalForwarder is EIP712 {
    using ECDSA for bytes32;

    struct ForwardRequest {
        address from;
        address to;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        bytes data;
    }

    bytes32 public constant FORWARD_REQUEST_TYPEHASH =
        keccak256("ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)");

    /// @notice Next valid request nonce per signer.
    mapping(address => uint256) public nonces;

    event Forwarded(address indexed from, address indexed to, uint256 nonce, bool success);

    error InvalidRequest();
    error ValueMismatch(uint256 expected, uint256 provided);

    constructor() EIP712("MinimalForwarder", "1") {}

    /// @notice EIP-712 digest the user must sign to authorize `req`.
    function requestHash(ForwardRequest calldata req) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    FORWARD_REQUEST_TYPEHASH, req.from, req.to, req.value, req.gas, req.nonce, keccak256(req.data)
                )
            )
        );
    }

    /// @notice True iff `signature` is `req.from`'s signature over `req` and
    ///         the nonce is current. Any tampering with the request (target,
    ///         calldata, value, gas budget…) changes the digest, recovers a
    ///         different signer, and fails here.
    function verify(ForwardRequest calldata req, bytes calldata signature) public view returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = requestHash(req).tryRecover(signature);
        return err == ECDSA.RecoverError.NoError && recovered == req.from && nonces[req.from] == req.nonce;
    }

    /// @notice Executes the signed request, forwarding `req.value` and at
    ///         most `req.gas` to the target with `req.from` appended to the
    ///         calldata per ERC-2771.
    /// @dev Returns the inner call's outcome instead of bubbling a failure:
    ///      the nonce is consumed either way (see contract docs), and the
    ///      relayer — the only party who can act on it — gets the result.
    function execute(ForwardRequest calldata req, bytes calldata signature)
        external
        payable
        returns (bool success, bytes memory returndata)
    {
        if (!verify(req, signature)) revert InvalidRequest();
        // The signer committed to `req.value`; make the relayer supply
        // exactly that so no ETH is ever stranded in the forwarder.
        if (msg.value != req.value) revert ValueMismatch(req.value, msg.value);

        nonces[req.from] = req.nonce + 1;

        (success, returndata) = req.to.call{gas: req.gas, value: req.value}(abi.encodePacked(req.data, req.from));

        // Relayer gas-griefing guard: a relayer could underfund the outer
        // transaction so the inner call dies out-of-gas while the nonce is
        // still consumed, silently burning the user's one-shot signature.
        // EIP-150 lets a call pass on at most 63/64 of remaining gas, so if
        // the inner call truly received its full `req.gas` budget, more than
        // req.gas/63 must remain here. Anything less means the relayer
        // shorted the request — consume all gas via `invalid` so the attempt
        // costs the relayer its full gas stipend and cannot be wrapped in a
        // cheap try/catch, and the state (including the nonce bump) reverts.
        if (gasleft() < req.gas / 63) {
            assembly {
                invalid()
            }
        }

        emit Forwarded(req.from, req.to, req.nonce, success);
    }
}
