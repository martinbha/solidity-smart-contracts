// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BondToken
/// @notice Mock ERC-20 used for optimistic-oracle assertion and dispute bonds.
///         The unrestricted mint keeps local demonstrations and tests focused
///         on the oracle's economic game rather than token distribution.
contract BondToken is ERC20 {
    constructor() ERC20("Oracle Bond Token", "BOND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
