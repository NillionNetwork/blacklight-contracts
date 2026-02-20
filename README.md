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

## Deployment

- Unified deploy entrypoint: `script/deployment/deploy.sh`
- Deployment script docs: `script/README.md`
- Operational runbook: `docs/deployment-runbook.md`

## Default Contract Addresses (Latest Local Deployment)

| Contract                     | Address                                      |
| ---------------------------- | -------------------------------------------- |
| STAKE_TOKEN                  | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| STAKING_OPERATORS            | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| WEIGHTED_COMMITTEE_SELECTOR  | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` |
| PROTOCOL_CONFIG              | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` |
| HEARTBEAT_MANAGER            | `0x0165878A594ca255338adfa4d48449f69242Eb8F` |
| REWARD_POLICY                | `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853` |
| SLASHING_POLICY              | `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318` |


## ERC 8004 Contract Addresses

| Contract                     | Address                                      |
| ---------------------------- | -------------------------------------------- |
| MINIMAL_UUPS_IMPL            | `0x0B306BF915C4d645ff596e518fAf3F9669b97016` |
| IDENTITY_REGISTRY_IMPL       | `0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1` |
| IDENTITY_REGISTRY            | `0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE` |
| VALIDATION_REGISTRY_IMPL     | `0x3Aa5ebB10DC797CAC828524e59A333d0A371443c` |
| VALIDATION_REGISTRY          | `0xc6e7DF5E7b4f2A278906862b61205850344D4e7d` |
| VALIDATION_HEARTBEAT_MANAGER | `0x0165878A594ca255338adfa4d48449f69242Eb8F` |
| REPUTATION_REGISTRY_IMPL     | `0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f` |
| REPUTATION_REGISTRY          | `0x4A679253410272dd5232B3Ff7cF5dbB88f295319` |

## NodeManager Contract Addresses

| Contract              | Address                                      |
| --------------------- | -------------------------------------------- |
| NODE_OPERATOR_FACTORY | `0x09635F643e140090A9A8Dcd712eD6285858ceBef` |

For full managed/unmanaged node lists, see `nodemanager_addresses.env`.
