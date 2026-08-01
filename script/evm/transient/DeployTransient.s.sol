// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransientVault} from "../../../src/evm/transient/TransientReentrancyGuard.sol";
import {StorageVault} from "../../../src/evm/transient/StorageReentrancyGuard.sol";
import {FlashAccountant, IFlashAccountantCallback} from "../../../src/evm/transient/FlashAccountant.sol";
import {PermitToken} from "../../../src/signatures/PermitToken.sol";

/// @notice Callback contract used by the local flash-accounting demonstration.
contract FlashAccountingDemo is IFlashAccountantCallback {
    FlashAccountant public immutable accountant;
    IERC20 public immutable token;

    constructor(FlashAccountant accountant_, IERC20 token_) {
        accountant = accountant_;
        token = token_;
        require(token_.approve(address(accountant_), type(uint256).max), "approve failed");
    }

    function run(uint256 amount, bool repay) external {
        accountant.lock(abi.encode(amount, repay));
    }

    function lockAcquired(bytes calldata data) external {
        require(msg.sender == address(accountant), "not accountant");
        (uint256 amount, bool repay) = abi.decode(data, (uint256, bool));

        accountant.take(address(token), amount);
        if (repay) accountant.settle(address(token));
    }
}

/// @notice Deploys the transient/storage guards and a funded flash-accounting
///         demonstration stack.
contract DeployTransient is Script {
    uint256 public constant ACCOUNTANT_LIQUIDITY = 1_000_000 ether;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        TransientVault transientVault = new TransientVault();
        StorageVault storageVault = new StorageVault();
        FlashAccountant accountant = new FlashAccountant();
        PermitToken token = new PermitToken();
        FlashAccountingDemo demo = new FlashAccountingDemo(accountant, IERC20(address(token)));
        token.mint(address(accountant), ACCOUNTANT_LIQUIDITY);

        vm.stopBroadcast();

        console.log("TRANSIENT_VAULT:", address(transientVault));
        console.log("STORAGE_VAULT:", address(storageVault));
        console.log("FLASH_ACCOUNTANT:", address(accountant));
        console.log("TOKEN:", address(token));
        console.log("FLASH_DEMO:", address(demo));
    }
}
