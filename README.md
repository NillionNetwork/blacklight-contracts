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
forge build
```

The project uses IR-based compilation to handle complex contracts. This is already configured in `foundry.toml`.

### Test

```shell
forge test
```

Run specific tests:
```shell
forge test --match-contract HeartbeatManagerTest
forge test --match-test test_submitHeartbeat -vvv
```
