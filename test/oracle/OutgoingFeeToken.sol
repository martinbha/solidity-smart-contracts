// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test token that burns 10% only when the configured sender transfers.
///      Incoming oracle deposits remain exact while outgoing rewards can be
///      exercised against recipient-side transfer fees.
contract OutgoingFeeToken is ERC20 {
    address public feeSender;

    constructor() ERC20("Outgoing Fee Token", "OFT") {}

    function setFeeSender(address sender) external {
        feeSender = sender;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == feeSender && to != address(0)) {
            uint256 fee = amount / 10;
            super._update(from, to, amount - fee);
            super._update(from, address(0), fee);
        } else {
            super._update(from, to, amount);
        }
    }
}
