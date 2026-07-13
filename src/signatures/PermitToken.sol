// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title PermitToken
/// @notice ERC20 with EIP-2612 `permit`: approvals by off-chain signature
///         instead of an on-chain `approve` transaction. The owner signs an
///         EIP-712 `Permit` payload and hands it to the spender, who submits
///         it (typically bundled with the `transferFrom` that uses it) — the
///         two-transaction approve-then-spend dance collapses into one, and
///         the token owner never needs ETH for the approval.
///
/// @dev Everything interesting lives in OZ `ERC20Permit`:
///
///      - The signed struct is
///        `Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)`
///        hashed under this token's EIP-712 domain (name "Permit Token",
///        version "1", this chain id, this contract address), so a permit
///        for one token can never be replayed on another token or chain.
///      - `nonce` is read from the contract per owner and bumped on use:
///        each signature authorizes exactly one allowance write, in order.
///        Replaying a consumed permit recomputes the digest with the new
///        nonce and recovers a different signer, which is rejected.
///      - `deadline` bounds the signature's lifetime; a permit floating
///        around in a mempool or a log cannot be redeemed forever.
///
///      The public unrestricted mint keeps local demos frictionless, matching
///      the other test assets in this repo.
contract PermitToken is ERC20Permit {
    constructor() ERC20("Permit Token", "PMT") ERC20Permit("Permit Token") {}

    /// @notice Mint `amount` tokens to `to`. Unrestricted by design (test asset).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
