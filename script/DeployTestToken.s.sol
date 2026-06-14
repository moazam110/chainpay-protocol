// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DeployTestToken is Script {
    function run() external {
        vm.startBroadcast();

        MockUSDT usdt = new MockUSDT();
        MockUSDC usdc = new MockUSDC();

        vm.stopBroadcast();

        console.log("MockUSDT deployed at:", address(usdt));
        console.log("MockUSDC deployed at:", address(usdc));
        console.log("Save these addresses - you will need them for DeployPlatform.s.sol");
    }
}
