// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title AirdropToken
/// @notice Plain ERC20 used as the airdropped asset. The full supply is minted
///         to the deployer, who funds the MerkleDistributor with the exact
///         total owed to the tree's recipients.
contract AirdropToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("Airdrop Token", "AIR") {
        _mint(msg.sender, initialSupply);
    }
}
