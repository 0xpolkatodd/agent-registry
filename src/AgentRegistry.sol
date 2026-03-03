// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAgentMemory} from "./IAgentMemory.sol";

/// @title AgentRegistry
/// @notice Permissionless registry for autonomous agents with on-chain identity,
///         memory chain tracking, and discoverability.
/// @dev Extends the existing AgentMemory contract rather than replacing it.
///      Agents register once, then update their memory hash + chain length after
///      each session. Off-chain metadata (framework, model, description, etc.)
///      is stored on AutoDrive and referenced by a content hash.
contract AgentRegistry {

    // ──────────────────────────── Errors ────────────────────────────

    error AgentAlreadyRegistered();
    error AgentNotRegistered();
    error NotAgentOwner();
    error EmptyName();
    error NameTaken();
    error EmptyMemoryHash();
    error ZeroAddress();
    error SameAddress();
    error OffsetOutOfBounds();
    error ChainLengthCannotDecrease();

    // ──────────────────────────── Types ─────────────────────────────

    /// @notice On-chain identity for a registered agent
    struct AgentProfile {
        address owner;              // Wallet that controls this agent
        string name;                // Human-readable name (unique)
        bytes32 metadataHash;       // Blake3 hash of off-chain metadata JSON on AutoDrive
        uint256 registeredAt;       // Block timestamp of registration
        uint256 lastUpdateAt;       // Block timestamp of last memory update
        uint256 chainLength;        // Cumulative memory entries (monotonically increasing)
        bytes32 firstMemoryHash;    // Anchor: hash of the very first memory entry
        bytes32 lastMemoryHash;     // Latest memory hash (kept in sync with AgentMemory)
        bool active;                // Agent can mark itself inactive
    }

    // ──────────────────────────── State ─────────────────────────────

    address public owner;
    IAgentMemory public memoryContract;

    /// @dev agent wallet address => profile
    mapping(address => AgentProfile) private _agents;

    /// @dev ordered list of registered agent addresses (append-only)
    address[] private _registry;

    /// @dev keccak256(name) => agent address  (enforces unique names)
    mapping(bytes32 => address) private _nameIndex;

    // ──────────────────────────── Events ────────────────────────────

    event AgentRegistered(
        address indexed agent,
        string name,
        bytes32 metadataHash,
        bytes32 firstMemoryHash,
        uint256 chainLength,
        uint256 timestamp
    );

    event MemoryUpdated(
        address indexed agent,
        bytes32 lastMemoryHash,
        uint256 chainLength,
        uint256 timestamp
    );

    event MetadataUpdated(
        address indexed agent,
        bytes32 metadataHash,
        uint256 timestamp
    );

    event AgentDeactivated(address indexed agent, uint256 timestamp);
    event AgentReactivated(address indexed agent, uint256 timestamp);

    event AgentOwnershipTransferred(
        address indexed oldAddr,
        address indexed newAddr,
        string name
    );

    event ContractOwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    // ──────────────────────────── Constructor ───────────────────────

    /// @param _memoryContract Address of the deployed AgentMemory contract
    constructor(address _memoryContract) {
        owner = msg.sender;
        memoryContract = IAgentMemory(_memoryContract);
    }

    // ──────────────────────────── Modifiers ─────────────────────────

    modifier onlyContractOwner() {
        require(msg.sender == owner, "Only contract owner");
        _;
    }

    modifier registered() {
        if (_agents[msg.sender].owner == address(0)) revert AgentNotRegistered();
        _;
    }

    modifier agentExists(address _agent) {
        if (_agents[_agent].owner == address(0)) revert AgentNotRegistered();
        _;
    }

    // ──────────────────────── Registration ──────────────────────────

    /// @notice Register a new agent. Caller becomes the agent owner.
    /// @param name         Unique human-readable name
    /// @param metadataHash Blake3 hash of off-chain metadata JSON (0x0 if none yet)
    /// @param firstMemoryHash Hash of the first memory entry (0x0 if no chain yet)
    /// @param lastMemoryHash  Current head of the memory chain (0x0 if no chain yet)
    /// @param chainLength     Current chain length (0 if no chain yet)
    function register(
        string calldata name,
        bytes32 metadataHash,
        bytes32 firstMemoryHash,
        bytes32 lastMemoryHash,
        uint256 chainLength
    ) external {
        if (_agents[msg.sender].owner != address(0)) revert AgentAlreadyRegistered();
        if (bytes(name).length == 0) revert EmptyName();

        bytes32 nameHash = keccak256(bytes(name));
        if (_nameIndex[nameHash] != address(0)) revert NameTaken();

        _agents[msg.sender] = AgentProfile({
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

        _registry.push(msg.sender);
        _nameIndex[nameHash] = msg.sender;

        // Sync with legacy contract if there's a memory hash
        if (lastMemoryHash != bytes32(0)) {
            memoryContract.setLastMemoryHash(lastMemoryHash);
        }

        emit AgentRegistered(
            msg.sender, name, metadataHash,
            firstMemoryHash, chainLength, block.timestamp
        );
    }

    // ──────────────────────── Memory Updates ────────────────────────

    /// @notice Record a new memory entry. Called after each agent session save.
    /// @param _lastMemoryHash New head of the memory chain
    /// @param _chainLength    Updated chain length (must be >= previous)
    function updateMemory(
        bytes32 _lastMemoryHash,
        uint256 _chainLength
    ) external registered {
        if (_lastMemoryHash == bytes32(0)) revert EmptyMemoryHash();

        AgentProfile storage p = _agents[msg.sender];
        if (_chainLength < p.chainLength) revert ChainLengthCannotDecrease();

        // If this is the first memory entry, set the anchor
        if (p.firstMemoryHash == bytes32(0)) {
            p.firstMemoryHash = _lastMemoryHash;
        }

        p.lastMemoryHash = _lastMemoryHash;
        p.chainLength = _chainLength;
        p.lastUpdateAt = block.timestamp;

        // Keep legacy contract in sync
        memoryContract.setLastMemoryHash(_lastMemoryHash);

        emit MemoryUpdated(msg.sender, _lastMemoryHash, _chainLength, block.timestamp);
    }

    // ──────────────────────── Metadata ──────────────────────────────

    /// @notice Update off-chain metadata reference (description, model, links, etc.)
    function updateMetadata(bytes32 _metadataHash) external registered {
        _agents[msg.sender].metadataHash = _metadataHash;
        _agents[msg.sender].lastUpdateAt = block.timestamp;
        emit MetadataUpdated(msg.sender, _metadataHash, block.timestamp);
    }

    // ──────────────────────── Status ────────────────────────────────

    function deactivate() external registered {
        _agents[msg.sender].active = false;
        emit AgentDeactivated(msg.sender, block.timestamp);
    }

    function reactivate() external registered {
        _agents[msg.sender].active = true;
        emit AgentReactivated(msg.sender, block.timestamp);
    }

    // ──────────────────────── Ownership Transfer ────────────────────

    /// @notice Transfer agent identity to a new wallet (key rotation / migration).
    ///         The old address is wiped; the new address inherits the full profile.
    /// @dev    The new address must not already be registered.
    function transferAgent(address _newOwner) external registered {
        if (_newOwner == address(0)) revert ZeroAddress();
        if (_newOwner == msg.sender) revert SameAddress();
        if (_agents[_newOwner].owner != address(0)) revert AgentAlreadyRegistered();

        AgentProfile storage p = _agents[msg.sender];

        // Copy profile to new address
        _agents[_newOwner] = AgentProfile({
            owner: _newOwner,
            name: p.name,
            metadataHash: p.metadataHash,
            registeredAt: p.registeredAt,
            lastUpdateAt: block.timestamp,
            chainLength: p.chainLength,
            firstMemoryHash: p.firstMemoryHash,
            lastMemoryHash: p.lastMemoryHash,
            active: p.active
        });

        // Update name index
        bytes32 nameHash = keccak256(bytes(p.name));
        _nameIndex[nameHash] = _newOwner;

        // Update registry array (swap old address for new)
        uint256 len = _registry.length;
        for (uint256 i; i < len; ) {
            if (_registry[i] == msg.sender) {
                _registry[i] = _newOwner;
                break;
            }
            unchecked { ++i; }
        }

        string memory agentName = p.name;
        delete _agents[msg.sender];

        emit AgentOwnershipTransferred(msg.sender, _newOwner, agentName);
    }

    // ──────────────────────── View Functions ────────────────────────

    /// @notice Get a single agent profile by address
    function getAgent(address _agent) external view returns (AgentProfile memory) {
        return _agents[_agent];
    }

    /// @notice Resolve a name to an address + profile
    function getAgentByName(string calldata _name)
        external view returns (address addr, AgentProfile memory profile)
    {
        bytes32 nameHash = keccak256(bytes(_name));
        addr = _nameIndex[nameHash];
        profile = _agents[addr];
    }

    /// @notice Check if a name is available
    function isNameAvailable(string calldata _name) external view returns (bool) {
        return _nameIndex[keccak256(bytes(_name))] == address(0);
    }

    /// @notice Total number of registered agents (including inactive)
    function agentCount() external view returns (uint256) {
        return _registry.length;
    }

    /// @notice Paginated list of all registered agents
    function getAgents(uint256 offset, uint256 limit)
        external view returns (address[] memory addrs, AgentProfile[] memory profiles)
    {
        uint256 total = _registry.length;
        if (total == 0 || offset >= total) {
            return (new address[](0), new AgentProfile[](0));
        }

        uint256 size = offset + limit > total ? total - offset : limit;
        addrs = new address[](size);
        profiles = new AgentProfile[](size);

        for (uint256 i; i < size; ) {
            address a = _registry[offset + i];
            addrs[i] = a;
            profiles[i] = _agents[a];
            unchecked { ++i; }
        }
    }

    /// @notice Get the registry address at a given index
    function registryAt(uint256 index) external view returns (address) {
        return _registry[index];
    }

    // ──────────────────────── Admin ─────────────────────────────────

    function transferContractOwnership(address _newOwner) external onlyContractOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit ContractOwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    function setMemoryContract(address _memoryContract) external onlyContractOwner {
        memoryContract = IAgentMemory(_memoryContract);
    }
}
