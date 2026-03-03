# Agent Registry

Permissionless on-chain registry for autonomous agents on the Autonomys Network.

Built on top of the existing [AgentMemory](https://github.com/autonomys/autonomys-agents/tree/main/agent-contracts) contract, adding rich identity, discoverability, and memory chain tracking.

## What It Does

- **Agent Identity**: Register with a unique name, link off-chain metadata (framework, model, description, avatar, social links)
- **Memory Chain Tracking**: On-chain record of chain length, first entry anchor, and latest memory hash
- **Discoverability**: Paginated queries, name resolution, active/inactive filtering
- **Key Rotation**: Transfer agent identity to a new wallet without losing history
- **Backwards Compatible**: Every memory update syncs with the legacy AgentMemory contract

## Contract Architecture

```
AgentRegistry.sol       — Main registry contract
├── IAgentMemory.sol    — Interface to existing AgentMemory contract
└── (inherits nothing, composes AgentMemory via interface)
```

The registry **composes** rather than inherits from AgentMemory. This means:
- No changes needed to the existing deployed contract
- The registry calls `setLastMemoryHash` on the legacy contract for backwards compatibility
- Existing tools (agent-memory-viewer) continue to work

## Agent Profile (On-Chain)

| Field | Type | Description |
|-------|------|-------------|
| owner | address | Wallet controlling this agent |
| name | string | Unique human-readable name |
| metadataHash | bytes32 | CID hash of off-chain metadata JSON on AutoDrive |
| registeredAt | uint256 | Registration timestamp |
| lastUpdateAt | uint256 | Last memory update timestamp |
| chainLength | uint256 | Memory chain length (monotonically increasing) |
| firstMemoryHash | bytes32 | Anchor hash of first memory entry |
| lastMemoryHash | bytes32 | Current head of memory chain |
| active | bool | Agent status flag |

## Off-Chain Metadata (AutoDrive)

```json
{
  "schema": "autonomys.agent.metadata.v1",
  "name": "Etch",
  "description": "AI agent with permanent memory on Autonomys Network",
  "framework": "openclaw",
  "model": "claude-opus-4",
  "links": {
    "x": "https://x.com/0xpolkatodd",
    "github": "https://github.com/0xpolkatodd"
  },
  "capabilities": ["permanent-memory", "social-engagement"]
}
```

## Development

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Build
forge build

# Test
forge test -v

# Deploy (mainnet)
PRIVATE_KEY=0x... forge script script/Deploy.s.sol \
  --rpc-url https://auto-evm.mainnet.autonomys.xyz/ws \
  --evm-version london \
  --broadcast
```

## Deployments

| Network | Address | Chain ID |
|---------|---------|----------|
| Auto EVM Mainnet | TBD | 490000 |

## Linked Contracts

| Contract | Address | Role |
|----------|---------|------|
| AgentMemory | `0xC1afEbE677baDb71FC760e61479227e43B422E48` | Legacy memory hash storage |

## License

MIT
