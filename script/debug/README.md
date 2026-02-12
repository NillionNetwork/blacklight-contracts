# Debug Scripts

This folder contains read-only introspection scripts for deployed contracts.

## Prerequisites

- An RPC endpoint (`RPC_URL`)
- Deployed contract addresses in your environment

Example:

```bash
export RPC_URL=http://localhost:8545
export STAKING_OPERATORS=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
export NODE_OPERATOR_FACTORY=0x7a2088a1bFc9d81c55368AE168C2C02570cB814F
```

## Scripts

### 1) `DebugApprovedStakers.s.sol`

Reports per operator/node:
- `approvedStaker`
- `operatorStaker`
- current `stake`
- active/jailed state
- operator metadata

Run with factory context (recommended):

```bash
STAKING_OPERATORS=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
NODE_OPERATOR_FACTORY=0x7a2088a1bFc9d81c55368AE168C2C02570cB814F \
forge script script/debug/DebugApprovedStakers.s.sol:DebugApprovedStakers \
  --rpc-url "$RPC_URL"
```

Run without factory (shows active operators only):

```bash
STAKING_OPERATORS=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
forge script script/debug/DebugApprovedStakers.s.sol:DebugApprovedStakers \
  --rpc-url "$RPC_URL"
```

### 2) `DebugNodeOperatorFactory.s.sol`

Reports:
- `NodeOperatorFactory` config/state
- all node <-> operator mappings
- assignment/free-node state
- per-`NodeOperator` config
- staking state for each node

```bash
NODE_OPERATOR_FACTORY=0x7a2088a1bFc9d81c55368AE168C2C02570cB814F \
forge script script/debug/DebugNodeOperatorFactory.s.sol:DebugNodeOperatorFactory \
  --rpc-url "$RPC_URL"
```

### 3) `stake_via_factory.sh`

Approves TEST to the factory and stakes through `NodeOperatorFactory.stake(uint256)` from the signer address.

Required env vars:
- `RPC_URL`
- `PRIVATE_KEY` (account that already has TEST)
- `NODE_OPERATOR_FACTORY`
- `AMOUNT_RAW` (raw token units; with 6 decimals, `10 TEST = 10000000`)

```bash
export RPC_URL=http://127.0.0.1:8545
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # Default for anvil
export NODE_OPERATOR_FACTORY=0x7a2088a1bFc9d81c55368AE168C2C02570cB814F
export AMOUNT_RAW=10000000
./script/debug/stake_via_factory.sh
```

Optional:
- `AUTO_APPROVE=true|false` (default `true`)

## Notes

- These scripts are `view` only and do not broadcast transactions.
- You can source addresses from `contract_addresses.env`:

```bash
source contract_addresses.env
```
