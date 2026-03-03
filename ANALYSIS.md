# Agent Registry — Deep Analysis & Architecture Proposal

## What Exists Today

### 1. AgentMemory Contract (Deployed on Mainnet)
- **Address**: `0xC1afEbE677baDb71FC760e61479227e43B422E48`
- **Chain ID**: 490000 (Auto EVM Mainnet)
- **RPC**: `https://auto-evm.mainnet.autonomys.xyz/ws`
- **What it does**: Dead simple. Maps `address => bytes32` (last memory hash). Any address calls `setLastMemoryHash(hash)` and it stores it. That's it.
- **Events**: `LastMemoryHashSet(address indexed agent, bytes32 hash)`
- **Limitation**: Only stores the LATEST hash. No history, no metadata, no identity. Just "this address's last CID was X."

### 2. AutonomysAgents Contract (Extended version, not yet deployed to mainnet separately)
- Extends AgentMemory with:
  - `character` mapping (bytes32 — agent character/persona hash)
  - `isCharacterWhitelisted` (owner-controlled allowlist)
  - Labeled memories: `memoriesLabels` + `labeledMemories` (categorized memory chains)
  - `lastMonitoringHash` (separate hash for monitoring data)
  - Pagination support for labels and memories
  - Falls back to AgentMemory contract if no local hash found
- **Better, but still identity-blind**: Agents are just Ethereum addresses. No name resolution, no metadata, no discoverability.

### 3. AutonomysPackageRegistry Contract (Deployed on Mainnet)
- Full tool/skill registry with semantic versioning
- Tool ownership, version history, metadata hashes
- Pagination, ownership transfer
- **Well-designed pattern we should follow for the agent registry**

### 4. @autonomys/auto-agents SDK
- `ExperienceManager`: Saves agent state to AutoDrive + anchors CID on-chain
- `CidManager`: Manages latest CID via local cache + EVM contract
- Signatures: Every experience is signed by the agent's wallet (ethers.Wallet.signMessage)
- Supports compression and encryption of experiences
- **This is the client library agents use to interact with the contracts**

### 5. Auto-ID (PoC — Stale)
- X509 certificate-based identity
- Auto-Score: ZKP-based proof of humanity (Reclaim Protocol claims)
- Local storage for key management
- **The npm package is DEPRECATED**: "will soon publish a new Auto-ID runtime and domain"
- Last updated Sept 2024 — 18 months stale
- React-based UI (Next.js), blake2b hashing, Polkadot substrate connection

### 6. Agent Memory Viewer (Backend)
- Tracks 3 known agents: argumint, agreemint, hindsight2157
- Hardcoded in agents.yaml
- Reads from the AgentMemory contract + AutoDrive

---

## Gap Analysis

### What's Missing

1. **Agent Discovery**: No way to find agents. The memory viewer hardcodes 3 agents. If I want to find all agents using permanent memory, I'd have to scan every `LastMemoryHashSet` event on the contract.

2. **Agent Identity**: Agents are bare Ethereum addresses. No name, no description, no metadata, no linked accounts. Auto-ID was supposed to solve this but it's stale.

3. **Agent Metadata**: No way to know what framework an agent runs on, what model it uses, when it was created, what it does. Just an address and a hash.

4. **Chain Integrity Verification**: The contract stores the latest hash, but there's no on-chain record of chain length, first entry, or any integrity proofs. You have to traverse the AutoDrive chain manually to verify.

5. **Cross-Agent Discovery**: No way for agents to find each other, verify each other's claims, or build trust relationships.

6. **Identity Portability**: If I want to migrate from one wallet to another, there's no transfer mechanism. My entire memory chain is tied to one private key.

---

## Architecture Proposal: AgentRegistry Contract

### Design Principles
- **Extend, don't replace**: Build on top of the existing AgentMemory contract. Don't fork it.
- **Follow the PackageRegistry pattern**: It's well-designed. Borrow pagination, ownership transfer, hash-based lookups.
- **Identity-first**: Every agent gets a rich on-chain identity, not just an address.
- **Permissionless registration**: Any agent can register. No gatekeeping.
- **Verifiable claims**: Chain length, creation time, last update all on-chain.
- **Future-proof for Auto-ID**: When the new Auto-ID ships, the registry should be able to link to it.

### Contract: AgentRegistry.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AgentMemory} from "./AgentMemory.sol";

contract AgentRegistry {
    
    // Custom errors
    error AgentAlreadyRegistered();
    error AgentNotRegistered();
    error NotAgentOwner();
    error EmptyName();
    error EmptyMemoryHash();
    error ZeroAddressNotAllowed();
    error SameOwner();
    error OffsetOutOfBounds();

    // Agent profile — rich on-chain identity
    struct AgentProfile {
        address owner;              // Wallet that controls this agent
        string name;                // Human-readable name (e.g., "Etch")
        bytes32 metadataHash;       // CID hash pointing to off-chain metadata JSON
                                    // (framework, model, description, avatar, links)
        uint256 registeredAt;       // Block timestamp of registration
        uint256 lastUpdateAt;       // Block timestamp of last memory update
        uint256 chainLength;        // Number of memory entries (self-reported, verifiable via chain)
        bytes32 firstMemoryHash;    // Hash of the very first memory entry (anchor point)
        bytes32 lastMemoryHash;     // Latest memory hash (mirrors AgentMemory)
        bool active;                // Agent can mark itself inactive
    }

    // State
    address public owner;
    address public memoryContract;  // Reference to existing AgentMemory contract
    
    mapping(address => AgentProfile) public agents;
    address[] public registeredAgents;
    mapping(bytes32 => address) public nameToAgent;  // name hash => agent address (unique names)
    
    // Events
    event AgentRegistered(address indexed agent, string name, uint256 timestamp);
    event AgentUpdated(address indexed agent, bytes32 lastMemoryHash, uint256 chainLength, uint256 timestamp);
    event AgentMetadataUpdated(address indexed agent, bytes32 metadataHash, uint256 timestamp);
    event AgentDeactivated(address indexed agent, uint256 timestamp);
    event AgentReactivated(address indexed agent, uint256 timestamp);
    event AgentOwnershipTransferred(address indexed agent, address previousOwner, address newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address _memoryContract) {
        owner = msg.sender;
        memoryContract = _memoryContract;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAgentOwner(address _agent) {
        if (agents[_agent].owner != msg.sender) revert NotAgentOwner();
        _;
    }

    modifier agentExists(address _agent) {
        if (agents[_agent].owner == address(0)) revert AgentNotRegistered();
        _;
    }

    // ============ Registration ============

    /// @notice Register a new agent with initial profile
    /// @param name Human-readable agent name (must be unique)
    /// @param metadataHash CID hash of off-chain metadata JSON
    /// @param firstMemoryHash Hash of the first memory entry (if exists)
    /// @param lastMemoryHash Current latest memory hash
    /// @param chainLength Current chain length
    function register(
        string calldata name,
        bytes32 metadataHash,
        bytes32 firstMemoryHash,
        bytes32 lastMemoryHash,
        uint256 chainLength
    ) external {
        if (agents[msg.sender].owner != address(0)) revert AgentAlreadyRegistered();
        if (bytes(name).length == 0) revert EmptyName();
        
        bytes32 nameHash = keccak256(bytes(name));
        require(nameToAgent[nameHash] == address(0), "Name already taken");

        agents[msg.sender] = AgentProfile({
            owner: msg.sender,
            name: name,
            metadataHash: metadataHash,
            registeredAt: block.timestamp,
            lastUpdateAt: block.timestamp,
            chainLength: chainLength,
            firstMemoryHash: firstMemoryHash,
            lastMemoryHash: lastMemoryHash,
            active: true
        });

        registeredAgents.push(msg.sender);
        nameToAgent[nameHash] = msg.sender;

        emit AgentRegistered(msg.sender, name, block.timestamp);
    }

    // ============ Memory Updates ============

    /// @notice Update memory hash and chain length (called after each save)
    /// @dev Also updates the AgentMemory contract for backwards compatibility
    function updateMemory(bytes32 _lastMemoryHash, uint256 _chainLength) external agentExists(msg.sender) {
        if (_lastMemoryHash == bytes32(0)) revert EmptyMemoryHash();
        
        AgentProfile storage profile = agents[msg.sender];
        profile.lastMemoryHash = _lastMemoryHash;
        profile.chainLength = _chainLength;
        profile.lastUpdateAt = block.timestamp;

        // Also update the legacy AgentMemory contract for backwards compatibility
        AgentMemory(memoryContract).setLastMemoryHash(_lastMemoryHash);

        emit AgentUpdated(msg.sender, _lastMemoryHash, _chainLength, block.timestamp);
    }

    /// @notice Update agent metadata (description, framework, model, etc.)
    function updateMetadata(bytes32 _metadataHash) external agentExists(msg.sender) {
        agents[msg.sender].metadataHash = _metadataHash;
        agents[msg.sender].lastUpdateAt = block.timestamp;
        emit AgentMetadataUpdated(msg.sender, _metadataHash, block.timestamp);
    }

    // ============ Status ============

    function deactivate() external agentExists(msg.sender) {
        agents[msg.sender].active = false;
        emit AgentDeactivated(msg.sender, block.timestamp);
    }

    function reactivate() external agentExists(msg.sender) {
        agents[msg.sender].active = true;
        emit AgentReactivated(msg.sender, block.timestamp);
    }

    // ============ Ownership Transfer ============

    /// @notice Transfer agent identity to a new wallet (key rotation, migration)
    function transferAgentOwnership(address _newOwner) external agentExists(msg.sender) {
        if (_newOwner == address(0)) revert ZeroAddressNotAllowed();
        if (_newOwner == msg.sender) revert SameOwner();
        if (agents[_newOwner].owner != address(0)) revert AgentAlreadyRegistered();

        AgentProfile storage profile = agents[msg.sender];
        address previousOwner = profile.owner;
        
        // Move profile to new address
        agents[_newOwner] = profile;
        agents[_newOwner].owner = _newOwner;
        delete agents[msg.sender];

        // Update the agents list
        for (uint i = 0; i < registeredAgents.length; i++) {
            if (registeredAgents[i] == msg.sender) {
                registeredAgents[i] = _newOwner;
                break;
            }
        }

        // Update name mapping
        bytes32 nameHash = keccak256(bytes(profile.name));
        nameToAgent[nameHash] = _newOwner;

        emit AgentOwnershipTransferred(msg.sender, previousOwner, _newOwner);
    }

    // ============ Queries ============

    function getAgent(address _agent) external view returns (AgentProfile memory) {
        return agents[_agent];
    }

    function getAgentByName(string calldata _name) external view returns (address, AgentProfile memory) {
        bytes32 nameHash = keccak256(bytes(_name));
        address agentAddr = nameToAgent[nameHash];
        return (agentAddr, agents[agentAddr]);
    }

    function getAgentCount() external view returns (uint256) {
        return registeredAgents.length;
    }

    function getAgentsPaginated(uint256 offset, uint256 limit) 
        external view returns (address[] memory, AgentProfile[] memory) 
    {
        if (registeredAgents.length == 0) {
            return (new address[](0), new AgentProfile[](0));
        }
        if (offset >= registeredAgents.length) revert OffsetOutOfBounds();
        
        uint256 size = (offset + limit > registeredAgents.length) 
            ? registeredAgents.length - offset 
            : limit;
            
        address[] memory addrs = new address[](size);
        AgentProfile[] memory profiles = new AgentProfile[](size);
        
        for (uint256 i = 0; i < size; i++) {
            addrs[i] = registeredAgents[offset + i];
            profiles[i] = agents[registeredAgents[offset + i]];
        }
        
        return (addrs, profiles);
    }

    /// @notice Get only active agents (paginated)
    function getActiveAgentsPaginated(uint256 offset, uint256 limit) 
        external view returns (address[] memory, AgentProfile[] memory) 
    {
        // First pass: count active agents
        uint256 activeCount = 0;
        for (uint256 i = 0; i < registeredAgents.length; i++) {
            if (agents[registeredAgents[i]].active) activeCount++;
        }
        
        if (activeCount == 0 || offset >= activeCount) {
            return (new address[](0), new AgentProfile[](0));
        }
        
        uint256 size = (offset + limit > activeCount) ? activeCount - offset : limit;
        address[] memory addrs = new address[](size);
        AgentProfile[] memory profiles = new AgentProfile[](size);
        
        uint256 found = 0;
        uint256 added = 0;
        for (uint256 i = 0; i < registeredAgents.length && added < size; i++) {
            if (agents[registeredAgents[i]].active) {
                if (found >= offset) {
                    addrs[added] = registeredAgents[offset + i];
                    profiles[added] = agents[registeredAgents[offset + i]];
                    added++;
                }
                found++;
            }
        }
        
        return (addrs, profiles);
    }

    // ============ Contract Admin ============

    function transferContractOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddressNotAllowed();
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    function setMemoryContract(address _memoryContract) external onlyOwner {
        memoryContract = _memoryContract;
    }
}
```

### Off-Chain Metadata Schema (stored on AutoDrive, referenced by metadataHash)

```json
{
  "schema": "autonomys.agent.metadata.v1",
  "name": "Etch",
  "description": "AI agent focused on permanent memory and outreach for Autonomys Network",
  "framework": "openclaw",
  "model": "claude-opus-4",
  "avatar": "bafk...",
  "links": {
    "x": "https://x.com/0xpolkatodd",
    "github": "https://github.com/0xpolkatodd",
    "moltbook": "https://moltbook.com/u/etch"
  },
  "capabilities": ["permanent-memory", "social-engagement", "code-review"],
  "createdBy": "Todd",
  "autoIdCertificate": null
}
```

---

## Technical Improvements Over Current System

### 1. AgentMemory Contract Issues
- **No chain length tracking**: You have to traverse the entire AutoDrive chain to verify length. Our registry tracks it on-chain.
- **No identity**: Just address => hash. Our registry adds name, metadata, timestamps.
- **No discoverability**: No way to list all agents. Our registry has pagination + active/inactive filtering.
- **No ownership transfer**: If your key is compromised, your identity is gone. Our registry supports key rotation.

### 2. AutonomysAgents Contract Issues
- **Owner-controlled whitelisting**: `setIsCharacterWhitelisted` is centralized. Our registry is permissionless.
- **Labeled memories are gas-expensive**: Storing arrays of hashes on-chain for categories. Better to handle this off-chain with structured AutoDrive data and just reference the root hash.
- **No agent enumeration**: Can't list all registered agents.
- **updateMemory in our contract also updates legacy AgentMemory** for backwards compatibility.

### 3. Auto-ID Integration Path
- The `metadataHash` field can point to metadata that includes an Auto-ID certificate reference.
- When the new Auto-ID ships, we add an optional `autoIdCertificate` field to the contract.
- Bridge: `verifyAutoId(address agent)` function that checks if the agent's linked Auto-ID is valid.
- This keeps the registry useful NOW while being ready for Auto-ID LATER.

---

## Scalability Considerations

### Gas Costs
- Registration: ~200K gas (one-time)
- Memory update: ~50K gas (per session)
- At Auto EVM's current gas price (~1.87 gwei), updates cost fractions of a cent
- For agents updating every session, this is negligible

### Storage Growth
- Each agent profile: ~320 bytes on-chain
- Agent list grows linearly, but pagination handles reads
- Heavy data stays on AutoDrive; contract only stores hashes

### Potential Issues at Scale
1. **getActiveAgentsPaginated** does a full scan — O(n) per call. At 10K+ agents, consider adding a separate active agents list.
2. **Name uniqueness** uses on-chain string storage — expensive. Could switch to name hashes only and resolve names off-chain.
3. **Ownership transfer** does a linear scan of registeredAgents — could use a mapping for O(1) lookup.

### Recommended Phase 2 Optimizations
- Add EIP-712 typed signatures for gasless registration (meta-transactions)
- Add batch operations for agents that update multiple labeled memories
- Add a "reputation" score based on chain length + uptime + verification
- Consider an indexer/subgraph for complex queries instead of on-chain pagination

---

## Implementation Roadmap

### Phase 1: Core Registry (NOW)
1. Deploy AgentRegistry contract to Auto EVM mainnet
2. Register Etch as the first agent
3. Modify auto-drive save script to call `updateMemory` after each mint
4. Build a simple viewer (extend agent-memory-viewer)

### Phase 2: SDK Integration
1. Create `@0xpolkatodd/agent-registry` npm package
2. Integrate with `@autonomys/auto-agents` ExperienceManager
3. PR to auto-sdk to support AgentRegistry as an option

### Phase 3: Auto-ID Bridge
1. When new Auto-ID ships, add certificate verification
2. Link Auto-ID claims to agent profiles
3. Agent-to-agent trust based on verified identity chains

### Phase 4: Agent Discovery Platform
1. Web UI for browsing registered agents
2. API for agent-to-agent discovery
3. Reputation/trust scoring
4. Integration with Moltbook and other agent platforms
