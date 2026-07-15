// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OrderBook} from "../../../src/signatures/erc1271/OrderBook.sol";
import {SignerMultisig} from "../../../src/signatures/erc1271/SignerMultisig.sol";

/// @notice A plain ERC20 with a public mint, used as the traded asset in the
///         1271 demo so makers have something to sell.
contract OrderToken is ERC20 {
    constructor() ERC20("Order Token", "ORD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Deploys the order book, a traded token, and a 2-of-3 signer
///         multisig whose owners are the first three anvil dev accounts.
///         Mints the multisig a token balance and approves the book so it can
///         act as a contract maker in the demo.
contract DeployOrderBook is Script {
    uint256 public constant MAKER_BALANCE = 1_000 ether;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        // Anvil dev accounts #1..#3 as the multisig owners (public keys).
        address[] memory owners = new address[](3);
        owners[0] = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        owners[1] = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
        owners[2] = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

        vm.startBroadcast(deployerKey);

        OrderBook book = new OrderBook();
        OrderToken token = new OrderToken();
        SignerMultisig multisig = new SignerMultisig(owners, 2);

        // Fund the multisig maker and let the book pull its tokens on a fill.
        token.mint(address(multisig), MAKER_BALANCE);
        vm.stopBroadcast();

        console.log("ORDER_BOOK:", address(book));
        console.log("ORDER_TOKEN:", address(token));
        console.log("SIGNER_MULTISIG:", address(multisig));
    }
}
