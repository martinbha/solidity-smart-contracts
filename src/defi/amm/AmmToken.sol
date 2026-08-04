// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title AmmToken
/// @notice Plain ERC20 with a public mint, used as a pooled asset in local
///         runs of the constant-product AMM demo. The open mint keeps testing
///         frictionless: anyone can conjure the two sides of a pair.
contract AmmToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Mint `amount` tokens to `to`. Unrestricted by design (test asset).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
