# Deployment Guide

This repository uses one deployment entrypoint:

```bash
./script/deployment/deploy.sh <target> [options]
```

## Targets

- `core`: deploy core Blacklight suite from typed config JSON.
- `erc8004`: deploy ERC-8004 suite.
- `node-factory`: deploy only `NodeOperatorFactory` (optional verify).
- `node-managers`: deploy managed nodes flow.
- `full-anvil`: deploy core + ERC-8004 + node managers for local Anvil.
- `testnet-with-verify`: full L1/L2 testnet flow with verification.
- `mainnet-with-verify`: full L1/L2 mainnet flow with verification.

## Prerequisites

1. Install Foundry and ensure `forge`, `cast`, `anvil` are available.
2. Use the pinned toolchain:
   - Foundry pin: `.tool-versions`
   - Solc pin: `foundry.toml`
3. Keep secrets in local untracked files (`.env.*.local`), not in committed files.

## Common Options

- `--profile <file>`: load `KEY=VALUE` file.
- `--profile-json <file>`: load top-level JSON keys as env vars.
- `--set KEY=VALUE`: override a value for one run.
- `--dry-run`: simulate without broadcast.
- `--resume` / `--no-resume`: reuse existing state outputs or force redeploy.
- `--expected-chain-id <id>`: fail fast if connected to wrong chain.
- `--config <file>`: typed JSON for `core` target.

## Anvil Deployment

1. Prepare profile:

```bash
cp script/deployment/profiles/anvil.env.sample .env.anvil.local
```

2. Start local chain:

```bash
anvil
```

3. Dry run:

```bash
./script/deployment/deploy.sh full-anvil --profile .env.anvil.local --dry-run --expected-chain-id 31337
```

Note: in `full-anvil --dry-run`, only `core` is simulated and plan artifacts are generated for downstream steps.  
This avoids false failures from simulated addresses not existing on-chain.

4. Broadcast:

```bash
./script/deployment/deploy.sh full-anvil --profile .env.anvil.local --expected-chain-id 31337
```

5. Outputs:
- `contract_addresses.env`
- `erc8004_addresses.env`
- `nodemanager_addresses.env`
- JSON artifacts in `target/deploy-artifacts/`

## Testnet Deployment

1. Prepare profile:

```bash
cp script/deployment/profiles/testnet.env.sample .env.testnet.local
```

2. Edit required values in `.env.testnet.local`:
- `PRIVATE_KEY`
- `L1_RPC_URL`
- chain guards (`EXPECTED_L1_CHAIN_ID`, `EXPECTED_L2_CHAIN_ID`)

3. Dry run:

```bash
./script/deployment/deploy.sh testnet-with-verify --profile .env.testnet.local --dry-run --resume
```

4. Broadcast:

```bash
./script/deployment/deploy.sh testnet-with-verify --profile .env.testnet.local --resume
```

5. Outputs:
- `target/deploy-testnet/addresses.env`
- `target/deploy-testnet/addresses.json`

## Mainnet Deployment

1. Prepare profile:

```bash
cp script/deployment/profiles/mainnet.env.sample .env.mainnet.local
```

2. Edit required values in `.env.mainnet.local`:
- `CONFIRM_MAINNET=yes`
- `PRIVATE_KEY`
- `L1_RPC_URL`, `L2_RPC_URL`
- `L1_BRIDGE`, `L1_NIL_ADDRESS`
- chain guards (`EXPECTED_L1_CHAIN_ID`, `EXPECTED_L2_CHAIN_ID`)

3. Dry run:

```bash
./script/deployment/deploy.sh mainnet-with-verify --profile .env.mainnet.local --dry-run --resume
```

4. Broadcast:

```bash
./script/deployment/deploy.sh mainnet-with-verify --profile .env.mainnet.local --resume
```

5. Outputs:
- `target/deploy-mainnet/addresses.env`
- `target/deploy-mainnet/addresses.json`

## Deploy Only NodeOperatorFactory

Use when core contracts already exist and you only need factory deployment.

1. Ensure profile includes:
- `RPC_URL`
- `PRIVATE_KEY`
- `STAKING_OPERATORS`
- `REWARD_POLICY`
- `STAKE_TOKEN`

2. Dry run:

```bash
./script/deployment/deploy.sh node-factory --profile .env.testnet.local --dry-run
```

3. Broadcast:

```bash
./script/deployment/deploy.sh node-factory --profile .env.testnet.local
```

4. Skip verify if needed:

```bash
./script/deployment/deploy.sh node-factory --profile .env.testnet.local --set SKIP_VERIFY=1
```

Output file: `node_factory.env`

## Typed Core Configs

For `core`, use typed JSON configs:

- `script/deployment/configs/core.anvil.json`
- `script/deployment/configs/core.testnet.json`
- `script/deployment/configs/core.mainnet.json`

Example:

```bash
./script/deployment/deploy.sh core --profile .env.anvil.local --config script/deployment/configs/core.anvil.json
```

## Safety and Behavior

- Chain ID checks prevent wrong-network deploys.
- Preflight interface checks validate dependency addresses.
- `--resume` reuses existing deployments only when bytecode is present.
- `--dry-run` disables broadcast and verification.

## Deploy NillionTokenOwner (H-3 Mitigation)

Locks down direct minting on an existing `NillionToken` by deploying a constrained
owner contract (`NillionTokenOwner`) and transferring token ownership to it.

The constrained owner exposes `setMinter()` and `transferTokenOwnership()` but
has no `mint()` function, so only whitelisted minters (e.g. `EmissionsController`)
can mint. No existing contracts need redeployment.

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `PRIVATE_KEY` | yes | Private key of the current token owner |
| `L1_NIL_ADDRESS` | yes | Address of the deployed `NillionToken` |
| `TOKEN_OWNER_ADMIN` | no | Admin of the new owner contract (defaults to deployer) |

### Dry Run

```bash
L1_NIL_ADDRESS=<token> PRIVATE_KEY=<key> \
  forge script script/deployment/DeployNillionTokenOwner.s.sol \
  --rpc-url <rpc>
```

### Broadcast

```bash
L1_NIL_ADDRESS=<token> PRIVATE_KEY=<key> \
  forge script script/deployment/DeployNillionTokenOwner.s.sol \
  --rpc-url <rpc> --broadcast
```

### Fork Test

Verify the migration e2e against a live token (no funds needed):

```bash
L1_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
  L1_NIL_ADDRESS=0xfa718d54f31bcf49CcaC3a79C276fa87d11E2F44 \
  forge test --match-contract NillionTokenOwnerForkTest -vv
```

## Related Docs

- Operational runbook: `docs/deployment-runbook.md`
- Debug scripts: `script/debug/README.md`
