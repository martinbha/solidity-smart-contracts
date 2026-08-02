// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BondToken} from "../../src/oracle/BondToken.sol";
import {OptimisticOracle} from "../../src/oracle/OptimisticOracle.sol";
import {InsurancePool} from "../../src/oracle/InsurancePool.sol";

/// @notice Deploys an optimistic oracle and a funded insurance policy for the
///         local end-to-end demonstration.
contract DeployOptimisticOracle is Script {
    uint256 public constant BOND = 100 ether;
    uint40 public constant CHALLENGE_WINDOW = 1 hours;
    uint256 public constant INSURANCE_PAYOUT = 500 ether;
    uint256 public constant POOL_LIQUIDITY = 10_000 ether;
    bytes32 public constant INSURED_CLAIM = keccak256("insured-event");

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address resolver = vm.envAddress("RESOLVER");
        address policyholder = vm.envAddress("POLICYHOLDER");

        vm.startBroadcast(deployerKey);

        BondToken bondToken = new BondToken();
        OptimisticOracle oracle = new OptimisticOracle(bondToken, resolver, BOND, CHALLENGE_WINDOW);
        InsurancePool insurancePool = new InsurancePool(oracle, bondToken);
        bondToken.mint(address(insurancePool), POOL_LIQUIDITY);
        insurancePool.createPolicy(INSURED_CLAIM, policyholder, INSURANCE_PAYOUT);

        vm.stopBroadcast();

        console.log("BOND_TOKEN:", address(bondToken));
        console.log("OPTIMISTIC_ORACLE:", address(oracle));
        console.log("INSURANCE_POOL:", address(insurancePool));
        console.log("BOND_AMOUNT:", BOND);
        console.log("CHALLENGE_WINDOW:", CHALLENGE_WINDOW);
        console.log("INSURANCE_PAYOUT:", INSURANCE_PAYOUT);
    }
}
