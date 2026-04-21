# Deployment Parameters and Mutability

This doc explains what each deployment-time parameter does, and whether it is
immutable (constructor-only) or can be changed later by governance/admin roles.
For live updates and operational guidance, also see `docs/live-parameter-controls.md`.

## Deployment Flow (High Level)

1) L1 NIL token (`NillionToken`)
2) L2 NIL token (`OptimismMintableERC20`)
3) L2 contract suite (`StakingOperators`, `WeightedCommitteeSelector`,
   `ProtocolConfig`, `HeartbeatManager`, `RewardPolicy`, `JailingPolicy`)
4) L1 emissions (`EmissionsController`)

The script `scripts/deploy_testnet_with_verify.sh` wires these together and
persists addresses in `target/deploy-testnet/addresses.env`.

## Roles and Authority

- Governance / owner: `ProtocolConfig`, `HeartbeatManager`, `RewardPolicy`,
  `EmissionsController`, `NillionToken`
- Admin roles: `StakingOperators` (`DEFAULT_ADMIN_ROLE`), `WeightedCommitteeSelector` (immutable `admin`)
- Submitter roles: `HeartbeatManager` (`HEARTBEAT_SUBMITTER_ROLE`, managed by `HEARTBEAT_SUBMITTER_ADMIN_ROLE`)
- `JailingPolicy` has no admin parameters; it only references a manager address.

## L1 NIL Token (NillionToken)

Constructor args:
- `owner` (address): initial owner and default minter.
  - Immutable: no (ownership can be transferred via OZ `Ownable`).
  - Governance changeable: yes (owner can transfer ownership).
- Name/symbol/decimals are hardcoded in the contract (`Nillion`, `NIL`, 6).
  - Immutable: yes (redeploy to change).

Post-deploy controls:
- `setMinter(address,bool)`: owner can add/remove minters.

## L2 NIL Token (OptimismMintableERC20)

Constructor args:
- `l2Bridge` (address): L2 StandardBridge that can mint/burn.
  - Immutable: yes (bridge-only).
- `l1Token` (address): L1 token address that this L2 token represents.
  - Immutable: yes.
- `name`, `symbol`, `decimals` (token metadata).
  - Immutable: yes.

Post-deploy controls: none (bridge is the sole minter/burner).

## L2 Contract Suite (DeployTestRCSystem.s.sol)

These are the key environment variables used to deploy the suite. All values
are set once at deploy time but most are stored in `ProtocolConfig`, which is
governance-updatable after deployment.

### Governance + admin
- `GOVERNANCE` (address): owner of `ProtocolConfig`, `HeartbeatManager`,
  `RewardPolicy`. Defaults to deployer.
  - Immutable: no (ownership can be transferred).
- `ADMIN` (address): `DEFAULT_ADMIN_ROLE` for `StakingOperators`. Defaults to deployer.
  - Immutable: no (role can be granted/revoked).

### Tokens and mocks
- `USE_MOCK_TOKENS` (bool): deploy TEST tokens if no token addresses provided.
  - Immutable: script-only.
- `STAKE_TOKEN`, `REWARD_TOKEN` (addresses): ERC20s used by staking and rewards.
  - Immutable in `StakingOperators`/`RewardPolicy`: yes (constructor args).
  - Change requires redeploy and `ProtocolConfig` module update.
- `MINT_RECIPIENT` (address): recipient of mock mints.
  - Immutable: script-only.
- `MOCK_STAKE_MINT`, `MOCK_REWARD_MINT` (uint256): mock mint amounts.
  - Immutable: script-only.

### Committee and round parameters (stored in ProtocolConfig)
- `BASE_COMMITTEE_SIZE` (uint32): target committee size at escalation level 0.
  - Immutable: no (ProtocolConfig `setParams`).
- `COMMITTEE_GROWTH_BPS` (uint32): size growth per escalation level.
  - Immutable: no.
- `MAX_COMMITTEE_SIZE` (uint32): cap on committee size.
  - Immutable: no.
- `MAX_ESCALATIONS` (uint8): number of escalation rounds before expiry.
  - Immutable: no.
- `QUORUM_BPS` (uint16): minimum responded stake for the round to be valid.
  - Immutable: no.
- `VERIFICATION_BPS` (uint16): minimum stake for valid/invalid threshold.
  - Immutable: no.
- `RESPONSE_WINDOW_SEC` (uint256): voting window per round.
  - Immutable: no.
- `JAIL_DURATION_SEC` (uint256): jail duration for jailable operators.
  - Immutable: no.
- `MAX_VOTE_BATCH` (uint256): max votes per batch; 0 means unlimited
  (still bounded by manager hard limit).
  - Immutable: no.
- `MIN_OPERATOR_STAKE` (uint256): minimum stake required to be active.
  - Immutable: no.
- `HEARTBEAT_SUBMITTERS` (comma-delimited addresses): initial HeartbeatManager submitter whitelist.
  - Immutable: no (managed via HeartbeatManager roles).

### Staking controls (StakingOperators)
- `UNSTAKE_DELAY_SEC` (uint256): delay before withdrawals can be claimed.
  - Immutable: no (admin can update within bounds of 1 minute to 14 days).

### Committee selector (WeightedCommitteeSelector)
- `MIN_COMMITTEE_VP` (uint256): minimum total committee voting power required.
  - Immutable: no (selector admin can update).
  - Note: selector admin is immutable; changing admin requires redeploy + ProtocolConfig update.

### Reward policy
- `REWARD_EPOCH_DURATION` (uint256): streaming duration for newly deposited rewards.
  - Immutable: no (RewardPolicy owner can update).
- `REWARD_MAX_PAYOUT_PER_FINALIZE` (uint256): cap per finalize (0 = unlimited).
  - Immutable: no (RewardPolicy owner can update).

### Module wiring (ProtocolConfig + StakingOperators)
The following are set during deployment, but can be changed later by governance:
- `ProtocolConfig.setModules(stakingOps, selector, slashing, reward)`
  - Immutable: no.
- `StakingOperators.setSnapshotter(address)`
  - Immutable: no.
- `StakingOperators.setHeartbeatManager(address)`
  - Immutable: no.

Note: `HeartbeatManager` snapshots `ProtocolConfig` settings at round start,
so parameter changes only affect new rounds.

## L1 Emissions Controller (DeployEmissionsController.s.sol)

Constructor args:
- `TOKEN` (address): L1 ERC20 mintable token.
  - Immutable: yes.
- `L1_BRIDGE` (address): L1 StandardBridge.
  - Immutable: yes.
- `L2_TOKEN` (address): L2 token address.
  - Immutable: yes.
- `REMAINDER_SINK_ADDR` (address): destination for any undistributed emission remainder.
  - Immutable: no (owner can call `setRemainderSink`).
- `REMAINDER_SINK_IS_L2` (bool): whether the remainder sink is on L2.
  - Immutable: no (owner can call `setRemainderSink`).
- `RECIPIENT_ADDRS` / `RECIPIENT_BPS` / `RECIPIENT_IS_L2`: initial recipient split.
  - Immutable: no (owner can add, remove, or update recipients).
- `EPOCH_START` (uint256): start timestamp for emissions schedule.
  - Immutable: yes.
- `EPOCH_DURATION` (uint256): seconds per emission epoch.
  - Immutable: yes.
- `L2_GAS_LIMIT` (uint32): L2 gas limit for bridge deposits.
  - Immutable: no (owner can call `setL2GasLimit`).
- `GLOBAL_MINT_CAP` (uint256): total mint cap across schedule (0 = unlimited).
  - Immutable: yes.
- `EMISSIONS_SCHEDULE` (uint256[]): per-epoch emission amounts.
  - Immutable: yes.
- `OWNER` (address): owner who can update `L2_GAS_LIMIT`, recipients, and remainder sink.
  - Immutable: no (ownership can be transferred).

## Script Parameters (Deployment-Time Only)

The following variables only affect the deployment process, not on-chain state:

- `PRIVATE_KEY`, `L1_RPC_URL`, `L2_RPC_URL`: RPC + signer.
- `L1_CHAIN`, `L2_CHAIN_ID`, `L1_VERIFIER_URL`, `L2_VERIFIER_URL`: verification
  settings.
- `SOLC_VERSION`, `SOLC_PATH`, `ETHERSCAN_API_VERSION`, `ETHERSCAN_VERIFIER_URL`:
  local verification tooling.
- `SKIP_DEPLOY_L1_NIL`, `SKIP_DEPLOY_L2_NIL`, `SKIP_DEPLOY_L2_SUITE`,
  `SKIP_DEPLOY_L1_EMISSIONS`, `SKIP_VERIFY`, `LOAD_STATE`: script flow switches.

## Immutability Summary

- Immutable in constructors (requires redeploy to change):
  - L1 token metadata (name/symbol/decimals)
  - L2 bridge token pairing (bridge, L1 token, metadata)
  - Emissions schedule and recipients (token, bridge, L2 token, L2 recipient,
    start time, epoch duration, global cap, per-epoch amounts)
  - Staking token and reward token addresses (StakingOperators, RewardPolicy)
- Governance/admin updatable:
  - ProtocolConfig params + module addresses
  - WeightedCommitteeSelector limits and min committee VP
  - StakingOperators operational settings (unstake delay, snapshotter, manager)
  - RewardPolicy epoch duration and payout cap
  - HeartbeatManager config + slashing gas limit
  - EmissionsController L2 gas limit
  - NillionToken minters and ownership
