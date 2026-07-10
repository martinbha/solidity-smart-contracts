// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title VaultAsset
/// @notice Plain ERC20 with a public mint, used as the underlying asset of the
///         yield vault. The open mint keeps local testing frictionless: anyone
///         can conjure principal for deposits or fund the mock yield source.
contract VaultAsset is ERC20 {
    constructor() ERC20("Vault Asset", "VAST") {}

    /// @notice Mint `amount` tokens to `to`. Unrestricted by design (test asset).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
