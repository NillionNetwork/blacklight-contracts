Live Parameter Controls

Overview
- Access control varies by contract: `ProtocolConfig` (owner/governance), `HeartbeatManager` (owner), `RewardPolicy` (owner), `StakingOperators` (DEFAULT_ADMIN_ROLE), `WeightedCommitteeSelector` (admin), `EmissionsController` (owner), `NillionToken` (owner).
- Changes apply immediately to new actions. Heartbeat rounds snapshot config at round start, so changing `ProtocolConfig`/selector settings will not change already-started rounds.
- Best practice: coordinate parameter changes with the keeper and operators, and avoid making disruptive changes mid-round or mid-reward epoch.

ProtocolConfig (owner/governance)
- setModules(stakingOps, selector, slashing, reward)
  - Bounds: all non-zero, must be deployed contracts (EOA is rejected).
  - Bad practice: swapping modules on a live system without coordinating keeper + operator updates; can strand funds and break round finalization.
- setParams(baseCommitteeSize, committeeSizeGrowthBps, maxCommitteeSize, maxEscalations, quorumBps, verificationBps, responseWindow, jailDuration, maxVoteBatchSize, minOperatorStake)
  - Bounds (enforced): quorumBps, verificationBps, committeeSizeGrowthBps in 1..10_000; responseWindow, jailDuration > 0 and <= uint64 max; baseCommitteeSize/maxCommitteeSize > 0 and base <= max; maxVoteBatchSize is 0 (unlimited) or <= 500.
  - Operational guidance:
    - Raising `minOperatorStake` can deactivate operators until they top up; do it with a grace period.
    - Aggressively lowering `responseWindow` can cause legitimate votes to miss deadlines.
    - Lowering `quorumBps`/`verificationBps` reduces safety margins; prefer gradual changes.

WeightedCommitteeSelector (admin)
- setMinCommitteeVP(newVP)
  - Bounds (enforced): > 0.
  - Bad practice: setting above active total stake; selection will revert with InsufficientCommitteeVP and rounds will stall.
- setMaxCommitteeSize(newSize)
  - Bounds (enforced): > 0.
  - Operational guidance: if this is lowered below `baseCommitteeSize`, `HeartbeatManager` will cap to the max; consider updating both.
- setMaxActiveOperators(newCap)
  - Bounds (enforced): 0 resets to default (1000); otherwise > 0.
  - Operational guidance: capping too low can starve committee diversity.

HeartbeatManager (owner)
- grantRole(HEARTBEAT_SUBMITTER_ROLE, submitter)
  - Admin: HEARTBEAT_SUBMITTER_ADMIN_ROLE (grant via AccessControl).
  - Behavior: only addresses with HEARTBEAT_SUBMITTER_ROLE can call submitHeartbeat.
- setConfig(newConfig)
  - Bounds (enforced): non-zero, must be a valid ProtocolConfig contract.
  - Behavior: only new rounds use the new config; existing rounds keep their snapshotted params.
  - Bad practice: switching configs without aligning `StakingOperators` and keeper settings.
- setSlashingGasLimit(newLimit)
  - Bounds (enforced): > 0.
  - Operational guidance: too low can cause slashing callbacks to fail; too high increases gas risk.
- pause/unpause
  - Use for emergency response only; pausing blocks heartbeats and voting.

StakingOperators (DEFAULT_ADMIN_ROLE)
- setProtocolConfig(newConfig)
  - Bounds (enforced): non-zero, must be a valid ProtocolConfig contract.
  - Behavior: affects future stake checks and snapshots; existing unbonding requests keep their stored ready time.
- setUnstakeDelay(newDelay)
  - Bounds (enforced): 1 minute to 14 days.
  - Operational guidance: changes apply to new unstake requests only.
- setMaxActiveOperators(newCap)
  - Bounds (enforced): > 0.
  - Bad practice: lowering below current active set can cause churn in selection.
- setSnapshotter(newSnapshotter), setHeartbeatManager(newHeartbeatManager)
  - Bounds (enforced): non-zero.
  - Operational guidance: coordinate with the keeper and any snapshot tooling.
- pause/unpause
  - Use sparingly; pausing blocks staking actions and operator updates.

RewardPolicy (owner)
- setEpochDuration(newDuration)
  - Bounds (enforced): > 0.
  - Operational guidance: changing while a stream is active alters unlock rate; prefer changes between reward epochs.
- setMaxPayoutPerFinalize(newCap)
  - Bounds: no on-chain cap; 0 means unlimited payout.
  - Operational guidance: too low can cause backlog of unpaid rewards.
- fund(amount), withdraw(amount, to), clearAccountingFreeze()
  - `clearAccountingFreeze` only succeeds when the contract is solvent; do not withdraw below reserved amounts.
  - Bad practice: withdrawing while rewards are pending can freeze accounting.

EmissionsController (owner)
- setL2GasLimit(newLimit)
  - Bounds: any uint32; higher values increase L1 cost of bridging.
- ensureBridgeApproval()
  - Permissionless; restores infinite allowance if it was reduced.
  - Emission schedule is immutable after deployment.

NillionToken (owner)
- setMinter(minter, allowed)
  - Bounds (enforced): minter != 0.
  - Operational guidance: keep the minter set small and auditable; revoke before rotation.
