// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CryptoPaymentPlatform.sol";

contract DeployPlatform is Script {
    uint256 constant DEFAULT_FEE_BPS = 250; // 2.5%

    function run() external {
        vm.startBroadcast();

        CryptoPaymentPlatform platform = new CryptoPaymentPlatform(DEFAULT_FEE_BPS);

        vm.stopBroadcast();

        console.log("=== CryptoPaymentPlatform deployed ===");
        console.log("Address :", address(platform));
        console.log("Version :", platform.VERSION());
        console.log("");
        console.log("Next: call addSupportedToken() as admin to enable ERC-20 tokens.");
        console.log("Native DC (address(0)) is already whitelisted automatically.");
    }
}
