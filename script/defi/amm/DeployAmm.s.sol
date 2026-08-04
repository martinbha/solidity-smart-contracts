// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AmmToken} from "../../../src/defi/amm/AmmToken.sol";
import {Pair} from "../../../src/defi/amm/Pair.sol";
import {PairFactory} from "../../../src/defi/amm/PairFactory.sol";

/// @notice Deploys two demo tokens, the pair factory, and the pool for them,
///         then seeds the pool at a 1:2 ratio so the demo has depth to trade
///         against and an initial price to move.
contract DeployAmm is Script {
    uint256 public constant SEED_A = 100_000 ether;
    uint256 public constant SEED_B = 200_000 ether;
    uint256 public constant SPARE = 1_000_000 ether;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        AmmToken tokenA = new AmmToken("Alpha", "ALPHA");
        AmmToken tokenB = new AmmToken("Beta", "BETA");
        PairFactory factory = new PairFactory();

        // The address is knowable before the pair exists; assert it to prove
        // the CREATE2 derivation rather than just claiming it.
        address predicted = factory.computePairAddress(address(tokenA), address(tokenB));
        Pair pair = Pair(factory.createPair(address(tokenA), address(tokenB)));
        require(address(pair) == predicted, "CREATE2 address mismatch");

        tokenA.mint(deployer, SEED_A + SPARE);
        tokenB.mint(deployer, SEED_B + SPARE);
        tokenA.approve(address(pair), type(uint256).max);
        tokenB.approve(address(pair), type(uint256).max);

        // Seed in sorted order — the pool knows nothing about A and B.
        bool aIsZero = pair.token0() == address(tokenA);
        pair.addLiquidity(aIsZero ? SEED_A : SEED_B, aIsZero ? SEED_B : SEED_A);
        pair.updateOracle();

        vm.stopBroadcast();

        console.log("AMM_TOKEN_A:", address(tokenA));
        console.log("AMM_TOKEN_B:", address(tokenB));
        console.log("AMM_FACTORY:", address(factory));
        console.log("AMM_PAIR:", address(pair));
        console.log("AMM_TOKEN0:", pair.token0());
        console.log("AMM_TOKEN1:", pair.token1());
    }
}
