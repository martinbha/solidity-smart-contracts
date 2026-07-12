// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlashToken} from "../../../src/defi/flashloan/FlashToken.sol";
import {FlashLender} from "../../../src/defi/flashloan/FlashLender.sol";
import {GoodBorrower} from "../../../src/defi/flashloan/GoodBorrower.sol";

/// @notice Deploys the flash-loan token, the ERC-3156 lender (0.09% fee), and
///         a well-behaved borrower, and seeds the lending pool so the demo
///         scripts have liquidity to borrow.
contract DeployFlashLender is Script {
    uint256 public constant FEE_BPS = 9; // 0.09%
    uint256 public constant POOL = 1_000_000 ether;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        FlashToken token = new FlashToken();
        FlashLender lender = new FlashLender(IERC20(address(token)), FEE_BPS);
        GoodBorrower borrower = new GoodBorrower(lender);

        token.mint(vm.addr(deployerKey), POOL);
        token.approve(address(lender), POOL);
        lender.fund(POOL);

        vm.stopBroadcast();

        console.log("FLASH_TOKEN:", address(token));
        console.log("FLASH_LENDER:", address(lender));
        console.log("GOOD_BORROWER:", address(borrower));
    }
}
