# Blacklight Smart Contracts

This repository contains the Solidity smart contracts for the Blacklight decentralized verifier network system.

## Core Contracts

- **HeartbeatManager** (`src/HeartbeatManager.sol`) - Orchestrates multi-round heartbeat verification with stake-weighted committees
- **StakingOperators** (`src/StakingOperators.sol`) - ERC20 staking registry with snapshot-based voting power
- **ProtocolConfig** (`src/ProtocolConfig.sol`) - Central governance-owned parameter store and module registry
- **WeightedCommitteeSelector** (`src/WeightedCommitteeSelector.sol`) - Stake-weighted random committee selection
- **RewardPolicy** (`src/RewardPolicy.sol`) - Streaming budget reward allocator with stake-weighted distribution
- **JailingPolicy** (`src/JailingPolicy.sol`) - Penalty enforcement through temporary operator jailing
- **EmissionsController** (`src/EmissionsController.sol`) - Token emissions scheduler with L1-to-L2 bridging
- **Interfaces** (`src/Interfaces.sol`) - Shared contract interfaces for pluggable modules

## Quick Start

### Install dependencies

### Install Foundry

```bash
# Install Foundry (forge, cast, anvil, chisel)
curl -L https://foundry.paradigm.xyz | bash

# Ensure foundryup is on your PATH (restart your shell if needed), then install binaries
foundryup

# Verify
forge --version
```

### Build

```shell
forge install # To install the dependencies
forge build
```
### Test

```shell
forge test
```

Run specific tests:
```shell
forge test --match-contract HeartbeatManagerTest
forge test --match-test test_submitHeartbeat -vvv
```

## Default Contract Addresses

| Contract                     | Address                                      |
| ---------------------------- | -------------------------------------------- |
| TEST_TOKEN                   | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| STAKING_OPERATORS            | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| WEIGHTED_COMMITTEE_SELECTOR  | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| PROTOCOL_CONFIG              | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` |
| HEARTBEAT_MANAGER            | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` |
| REWARD_POLICY                | `0x0165878A594ca255338adfa4d48449f69242Eb8F` |
| SLASHING_POLICY              | `0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6` |


## ERC 8004 Contract Addresses

| Contract                     | Address                                      |
| ---------------------------- | -------------------------------------------- |
| MINIMAL_UUPS_IMPL            | `0x9A676e781A523b5d0C0e43731313A708CB607508` |
| IDENTITY_REGISTRY_IMPL       | `0x0B306BF915C4d645ff596e518fAf3F9669b97016` |
| IDENTITY_REGISTRY            | `0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1` |
| VALIDATION_REGISTRY_IMPL     | `0x68B1D87F95878fE05B998F19b66F4baba5De1aed` |
| VALIDATION_REGISTRY          | `0x3Aa5ebB10DC797CAC828524e59A333d0A371443c` |
| VALIDATION_HEARTBEAT_MANAGER | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` |
| REPUTATION_REGISTRY_IMPL     | `0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44` |
| REPUTATION_REGISTRY          | `0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f` |
