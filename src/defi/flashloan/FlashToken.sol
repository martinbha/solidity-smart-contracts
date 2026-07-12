// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FlashToken
/// @notice Plain ERC20 with a public mint, used as the pooled asset in local
///         runs of the flash-loan demo. The open mint keeps testing
///         frictionless: anyone can conjure liquidity to seed the pool or
///         fund the vulnerable bank.
contract FlashToken is ERC20 {
    constructor() ERC20("Flash Token", "FLASH") {}

    /// @notice Mint `amount` tokens to `to`. Unrestricted by design (test asset).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
