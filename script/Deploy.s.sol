// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/AgentRegistry.sol";

contract DeployScript is Script {
    // Existing AgentMemory contract on Auto EVM Mainnet
    address constant AGENT_MEMORY_MAINNET = 0xC1afEbE677baDb71FC760e61479227e43B422E48;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        AgentRegistry registry = new AgentRegistry(AGENT_MEMORY_MAINNET);
        vm.stopBroadcast();

        console.log("AgentRegistry deployed at:", address(registry));
        console.log("Linked to AgentMemory at:", AGENT_MEMORY_MAINNET);
    }
}
