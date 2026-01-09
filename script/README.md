# Deployment Scripts

## Quick Start - Deploy Complete System

You can deploy the complete Blacklight system in two ways:

### Option 1: Using the Shell Script (Easiest)

The `deploy_anvil.sh` script handles everything automatically and saves addresses to an env file:

```bash
# Terminal 1: Start Anvil
anvil

# Terminal 2: Deploy
./script/deploy_anvil.sh

# Use the deployed contracts
source script/anvil.env
```

This is the easiest option for local development. The script checks prerequisites, deploys everything, extracts addresses, and provides usage examples.

### Option 2: Using the Forge Script Directly

Deploy the complete Blacklight verifier network in one command:

```bash
# Deploy to Anvil (local testnet)
# In terminal 1: Start Anvil
anvil

# In terminal 2: Deploy
forge script script/DeployBlacklight.s.sol:DeployBlacklight \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

### Deploy to Production Networks

```bash
# Set your private key
export PRIVATE_KEY=0x...

# Deploy to Sepolia
forge script script/DeployBlacklight.s.sol:DeployBlacklight \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify

# Deploy to Mainnet (use with caution!)
forge script script/DeployBlacklight.s.sol:DeployBlacklight \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  --verify
```

## Configuration Options

The deployment script supports configuration via environment variables:

```bash
# Staking parameters
export UNSTAKE_DELAY=604800              # 7 days (default)
export MIN_OPERATOR_STAKE=1000000000000000000000  # 1000e18 (default)

# Committee parameters
export BASE_COMMITTEE_SIZE=5             # Initial committee size (default: 5)
export MAX_COMMITTEE_SIZE=20             # Maximum committee size (default: 20)
export MAX_ESCALATIONS=3                 # Max escalation rounds (default: 3)

# Voting parameters
export QUORUM_BPS=5000                   # 50% quorum (default: 5000 = 50%)
export VERIFICATION_BPS=6667             # 66.67% verification threshold (default: 6667)
export RESPONSE_WINDOW=3600              # 1 hour response window (default: 3600)
export JAIL_DURATION=86400               # 1 day jail duration (default: 86400)

# Policy selection
export USE_NOOP_SLASHING=false           # Use NoOpSlashingPolicy instead of JailingPolicy (default: false)
export DEPLOY_EMISSIONS=false            # Deploy EmissionsController (default: false)

# Run deployment with custom config
forge script script/DeployBlacklight.s.sol:DeployBlacklight \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

## What Gets Deployed

The `DeployBlacklight.s.sol` script deploys the complete Blacklight system:

1. **Tokens**:
   - `MockERC20` - Stake token (BLSTK)
   - `MockERC20` - Reward token (BLRWD)

2. **Core Contracts**:
   - `StakingOperators` - Operator registry and stake management
   - `WeightedCommitteeSelector` - Stake-weighted committee selection
   - `ProtocolConfig` - Central parameter store and module registry
   - `HeartbeatManager` - Multi-round verification orchestrator
   - `RewardPolicy` - Streaming reward distribution
   - `JailingPolicy` or `NoOpSlashingPolicy` - Penalty enforcement

3. **Optional**:
   - `EmissionsController` - Token emissions scheduler (if DEPLOY_EMISSIONS=true)
   - `MockL1StandardBridge` - Mock bridge for testing

4. **Wiring**:
   - All contracts are properly connected and configured
   - Roles and permissions are set up
   - System is ready to use immediately after deployment

## After Deployment

The script outputs all deployed addresses. Next steps:

1. **Fund operators** with stake tokens:
   ```solidity
   stakeToken.mint(operatorAddress, amount)
   ```

2. **Operators register**:
   ```solidity
   stakingOps.registerOperator("ipfs://metadata-uri")
   ```

3. **Operators stake**:
   ```solidity
   stakeToken.approve(stakingOps, amount)
   stakingOps.stakeTo(operatorAddress, amount)
   ```

4. **Fund reward pool**:
   ```solidity
   rewardToken.mint(rewardPolicyAddress, amount)
   rewardPolicy.syncAndUpdate() // Optional: set up streaming
   ```

5. **Submit heartbeats**:
   ```solidity
   manager.submitHeartbeat(htxHash, rawHTX)
   ```

## Legacy Scripts (Deprecated)

The following scripts are deprecated and have been renamed with `.old` extension:
- `DeployAll.s.sol.old` - Referenced non-existent contracts
- `DeployRouter.s.sol.old` - Referenced non-existent NilAVRouter
- `DeployStaking.s.sol.old` - Incomplete deployment
- `FundOperator.s.sol.old` - Use DeployBlacklight instead
- `TransferAndStake.s.sol.old` - Use DeployBlacklight instead

Use `DeployBlacklight.s.sol` for all new deployments.

## Helper Scripts

### deploy_anvil.sh (Interactive Deployment)

Quick deployment wrapper that deploys to Anvil and saves all addresses to an env file:

```bash
# Terminal 1: Start Anvil
anvil

# Terminal 2: Deploy
./script/deploy_anvil.sh

# This creates script/anvil.env with all contract addresses
# Source it to use the contracts:
source script/anvil.env

# Now you can interact with contracts using cast:
cast send $STAKE_TOKEN_ADDRESS "mint(address,uint256)" $YOUR_ADDRESS 1000000000000000000000 --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

The script automatically:
- Checks if Anvil is running
- Deploys all Blacklight contracts
- Extracts contract addresses from the broadcast file
- Writes them to `script/anvil.env`
- Provides next steps for interacting with the system

### deploy.sh (Docker-Friendly Deployment)

Simplified deployment script designed to work with the Docker setup in `docker/start-anvil.sh`:

```bash
# Usage (called by docker/start-anvil.sh)
./script/deploy.sh all

# Or run directly
./script/deploy.sh
```

This script:
- Deploys all Blacklight contracts
- Extracts contract addresses
- Writes them to `script/anvil.env` and `script/fund_operator.env`
- Works seamlessly in Docker containers

### fund_operator.sh (Operator Funding)

Fund operators with stake tokens and ETH:

```bash
# Usage
./script/fund_operator.sh <env_file> <operator_address> <token_amount> <eth_amount>

# Example: Fund operator with 50 stake tokens and 10 ETH
./script/fund_operator.sh ./script/fund_operator.env 0x976EA74026E726554dB657fA54763abd0C3a0aa9 50 10
```

This script:
- Sources the env file to get contract addresses
- Mints stake tokens to the operator address
- Sends ETH to the operator address
- Used by `docker/start-anvil.sh` to fund multiple operators automatically

### Other Helper Scripts

The following scripts may need updating to work with the new contract structure:
- `deploy_local.sh` - Legacy local deployment script
- `stake_node.sh` - Operator staking helper

## Docker Deployment

The `docker/start-anvil.sh` script uses these scripts to set up a complete test environment:

```bash
# In docker/start-anvil.sh:
# 1. Start Anvil
# 2. Deploy contracts via deploy.sh
# 3. Fund operators via fund_operator.sh
# 4. Keep Anvil running
```

### Git "dubious ownership" inside Docker

If you bind-mount your working tree into the container (e.g. `-v "$PWD:/app"`), Git may refuse to operate on the repo or nested submodules with:

- `fatal: detected dubious ownership in repository at '/app/...'`

This happens when the container user UID/GID differs from the host file ownership.

Recommended fix (no `safe.directory` needed): run the container as your host user:

```bash
./docker/run-anvil-dev.sh
```

Alternative: avoid bind-mounting the full repository (mount only `src/`/`test/`/`script/`) and keep `lib/` inside the container/volume so Git never touches host-owned submodules.

## Troubleshooting

### "Stack too deep" errors

If you encounter stack too deep errors, ensure your `foundry.toml` has:

```toml
[profile.default]
via_ir = true
optimizer = true
optimizer_runs = 200
```

This enables the IR-based compiler which handles complex contracts better.

### Deployment fails on verification

If contract verification fails, you can verify manually later:

```bash
forge verify-contract \
  --chain-id 11155111 \
  --constructor-args $(cast abi-encode "constructor(address)" "0x...") \
  CONTRACT_ADDRESS \
  src/ContractName.sol:ContractName \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Need different token names?

Edit the deployment script `DeployBlacklight.s.sol` and modify the MockERC20 constructor calls:

```solidity
deployed.stakeToken = new MockERC20("Your Stake Token", "YSTK");
deployed.rewardToken = new MockERC20("Your Reward Token", "YRWD");
```

For production, replace MockERC20 with your actual token contracts.
