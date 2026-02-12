# Deployment Runbook

## Scope

Operational procedure for deploying Blacklight contracts across local Anvil, testnet, and mainnet with reproducible artifacts.

## Preconditions

- Toolchain is pinned in `.tool-versions` and `foundry.toml`.
- Secrets are loaded from local ignored files or CI secret manager.
- A config file exists for core deployment (`script/deployment/configs/*.json`).

## Local (Anvil)

1. Start local chain (`anvil`).
2. Copy and edit profile: `cp script/deployment/profiles/anvil.env.sample .env.anvil`.
3. Dry run first:
   - `./script/deployment/deploy.sh full-anvil --profile .env.anvil --dry-run --expected-chain-id 31337`
4. Broadcast:
   - `./script/deployment/deploy.sh full-anvil --profile .env.anvil --expected-chain-id 31337`
5. Confirm artifacts in `target/deploy-artifacts/`.

## Testnet

1. Copy and edit profile: `cp script/deployment/profiles/testnet.env.sample .env.testnet`.
2. Dry run first:
   - `./script/deployment/deploy_testnet_with_verify.sh --profile .env.testnet --dry-run --resume`
3. Broadcast:
   - `./script/deployment/deploy_testnet_with_verify.sh --profile .env.testnet --resume`
4. Save generated state + JSON artifact from `target/deploy-testnet/`.

## Mainnet

1. Copy and edit profile: `cp script/deployment/profiles/mainnet.env.sample .env.mainnet`.
2. Dry run first:
   - `./script/deployment/deploy_mainnet_with_verify.sh --profile .env.mainnet --dry-run --resume`
3. Broadcast:
   - `./script/deployment/deploy_mainnet_with_verify.sh --profile .env.mainnet --resume`
4. Archive generated state + JSON artifact from `target/deploy-mainnet/`.

## Rollback Strategy

- Deployments are immutable; rollback means switching integrations/governance references to previous verified addresses.
- Keep prior `addresses.env` + JSON artifact snapshots versioned by timestamp.
- For parameter mistakes, deploy corrected instances and update consumers via governance/config updates.

## Verification Checklist

- Chain id guard passed for all RPC endpoints.
- Preflight interface checks passed for all dependency addresses.
- All expected addresses have bytecode (`cast code`).
- Contract verification submitted/succeeded where required.
- Artifacts generated (`addresses.env`, `addresses.json`) and archived.
