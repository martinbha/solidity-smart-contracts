// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title StreamToken
/// @notice Plain ERC20 with a public mint, used as the streamed asset in local
///         runs of the payment streaming demo. The open mint keeps testing
///         frictionless: anyone can conjure funds to open a stream with.
contract StreamToken is ERC20 {
    constructor() ERC20("Stream Token", "STRM") {}

    /// @notice Mint `amount` tokens to `to`. Unrestricted by design (test asset).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
