// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VaultAsset} from "../../../src/defi/VaultAsset.sol";
import {ERC6551Registry} from "../../../src/nft/erc6551/ERC6551Registry.sol";
import {TokenBoundAccount} from "../../../src/nft/erc6551/TokenBoundAccount.sol";
import {ProfileNFT} from "../../../src/nft/erc6551/ProfileNFT.sol";

/// @notice Deploys the ERC-6551 example, mints a profile, and creates its
///         deterministic token-bound account.
contract DeployTokenBound is Script {
    bytes32 public constant ACCOUNT_SALT = bytes32(0);

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address profileOwner = vm.envAddress("PROFILE_OWNER");

        vm.startBroadcast(deployerKey);

        ERC6551Registry registry = new ERC6551Registry();
        TokenBoundAccount implementation = new TokenBoundAccount();
        ProfileNFT profile = new ProfileNFT();
        VaultAsset asset = new VaultAsset();
        uint256 tokenId = profile.mint(profileOwner);
        address account =
            registry.createAccount(address(implementation), ACCOUNT_SALT, block.chainid, address(profile), tokenId);

        vm.stopBroadcast();

        console.log("ERC6551_REGISTRY:", address(registry));
        console.log("TOKEN_BOUND_IMPLEMENTATION:", address(implementation));
        console.log("PROFILE_NFT:", address(profile));
        console.log("PROFILE_ASSET:", address(asset));
        console.log("PROFILE_TOKEN_ID:", tokenId);
        console.log("TOKEN_BOUND_ACCOUNT:", account);
    }
}
