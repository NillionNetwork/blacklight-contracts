Policy and Module Upgrade Guide

Purpose
- This document explains how to update policies or replace components after the system is live.
- It highlights ordering, compatibility concerns, and common failure modes.
- It should be used with `docs/live-parameter-controls.md` and `docs/contract-overview.md`.

General Principles
- Prefer parameter changes over module swaps when possible.
- Make changes at round or epoch boundaries to avoid mixed-configuration behavior.
- Coordinate with the keeper and operators before modifying live settings.
- Keep a rollback plan: old contract addresses and config should be retained for quick recovery.

Parameter Updates vs Module Replacement
- Parameter updates are lower-risk and can be performed via governance or admin roles.
- Module replacements change core behavior and require extra validation:
  - Interface compatibility (function signatures, invariants).
  - State migration (if the new module needs existing state).
  - Keeper and tooling updates (new addresses, new event formats).

Safe Change Windows
- Heartbeat rounds snapshot configuration at round start.
  - Updating config mid-round does not change the current round.
  - Changes apply only to new rounds.
- RewardPolicy changes can affect current reward streams.
  - Prefer updates at epoch boundaries or after pausing reward distribution.
- StakingOperators changes (min stake, active cap) can change the active set immediately.

Replacing ProtocolConfig
1) Deploy a new ProtocolConfig with the intended module addresses and parameters.
2) Verify the new config returns correct values and module addresses.
3) Update HeartbeatManager via `setConfig(newConfig)`.
4) Update StakingOperators via `setProtocolConfig(newConfig)`.
5) Confirm new rounds reference the new config (check round data).
Gotchas
- If module addresses are inconsistent between HeartbeatManager and StakingOperators, snapshots and committee selection can break.
- Changing committee sizing or quorum values too aggressively can stall finalization.

Replacing StakingOperators
1) Deploy the new StakingOperators and migrate or re-register operators.
2) Ensure snapshot behavior matches what HeartbeatManager expects.
3) Update ProtocolConfig to point to the new StakingOperators.
4) Update HeartbeatManager and any snapshot tooling.
Gotchas
- Existing operator stakes are not automatically migrated.
- Jailing/slashing roles must be re-assigned.
- If the active set is empty, committee selection will revert.

Replacing WeightedCommitteeSelector
1) Deploy the new selector and validate selection behavior on a fork.
2) Update ProtocolConfig module address.
3) Start new rounds and confirm committee selection succeeds.
Gotchas
- Setting `minCommitteeVP` too high will revert selection.
- Large committee sizes can cause high gas and OOG risk for verification.

Replacing RewardPolicy
1) Deploy the new RewardPolicy with the expected epoch and payout settings.
2) Fund the new policy with L2 NIL and verify accounting is healthy.
3) Update ProtocolConfig module address.
4) Validate `distributeRewards` against the new policy on a fork.
Gotchas
- If the policy is underfunded, accounting can freeze.
- Changing payout caps too low can backlog rewards.

Replacing Slashing/Jailing Policy
1) Deploy the new policy contract.
2) Update ProtocolConfig module address.
3) Ensure the policy supports expected calls from HeartbeatManager.
Gotchas
- Policy code that reverts will not stop round finalization, but will skip penalties.
- If the policy uses Merkle proofs or committee lists, it must agree with HeartbeatManager's root format.

Replacing HeartbeatManager
1) Deploy the new HeartbeatManager.
2) Update StakingOperators `setHeartbeatManager` and `setSnapshotter` (if needed).
3) Update ProtocolConfig module address for slashing and reward policy if required.
4) Re-grant `HEARTBEAT_SUBMITTER_ROLE` to the desired submitter set (the new manager starts with a fresh AccessControl state).
5) Update the keeper to watch the new manager address.
Gotchas
- Active rounds in the old manager will remain unresolved unless explicitly finalized.
- Voting proofs and round roots are manager-specific.

Replacing EmissionsController
1) Deploy a new EmissionsController with the desired schedule and recipient.
2) On L1 NIL, update minter permissions to grant the new controller and revoke the old.
3) Confirm bridge allowance and gas limit settings.
Gotchas
- Emissions schedule is immutable per deployment; a new schedule requires a new contract.
- If the L2 recipient changes, reward accounting assumptions may need updates.

Operational Checklist
- Run the keeper against a forked environment with the new modules.
- Validate a full heartbeat lifecycle (submit, vote, finalize, rewards, jailing).
- Verify that all module addresses in ProtocolConfig are deployed contracts.
- Confirm operator and committee sizes remain within safe bounds.
- Monitor for reward accounting freezes after changes.

Emergency Response
- Use pause controls on HeartbeatManager and StakingOperators if a bad config is detected.
- Revert to the last known-good ProtocolConfig or modules.
- Communicate changes and any expected downtime to operators.
