// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAgentMemory
/// @notice Interface for the existing AgentMemory contract on Auto EVM mainnet
/// @dev Deployed at 0xC1afEbE677baDb71FC760e61479227e43B422E48
interface IAgentMemory {
    event LastMemoryHashSet(address indexed agent, bytes32 hash);

    function setLastMemoryHash(bytes32 hash) external;
    function getLastMemoryHash(address _agent) external view returns (bytes32);
    function lastMemoryHash(address) external view returns (bytes32);
}
