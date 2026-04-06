// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import "./helpers/BlacklightFixture.sol";
import "../src/Interfaces.sol";

contract RevertingSlashingPolicy is ISlashingPolicy {
    function onRoundFinalized(bytes32, uint8, Outcome, bytes32, uint32) external pure override {
        revert("slashing-revert");
    }
}

contract KeeperE2EPathsTest is BlacklightFixture {
    using stdStorage for StdStorage;

    function _fundRewards(uint256 amount) internal {
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(rewardPolicy), amount);
        rewardPolicy.fund(amount);
    }

    function _heartbeatStatus(bytes32 heartbeatKey)
        internal
        view
        returns (HeartbeatManager.HeartbeatStatus status, uint8 round)
    {
        uint8 escalationLevel;
        uint8 maxEscalationsSnapshot;
        uint64 createdAt;
        bytes32 rawHTXHash;
        address submitter;
        (status, round, escalationLevel, maxEscalationsSnapshot, createdAt, rawHTXHash, submitter) =
            manager.heartbeats(heartbeatKey);
    }

    function _roundMeta(bytes32 heartbeatKey, uint8 round)
        internal
        view
        returns (uint32 committeeSize, uint64 snapshotId, bytes32 committeeRoot, uint64 deadline)
    {
        uint256 validStake;
        uint256 invalidStake;
        uint256 errorStake;
        uint256 totalRespondedStake;
        uint256 committeeTotalStake;
        uint64 startedAt;
        bool finalized;
        address stakingOps;
        address selector;
        address slashing;
        address reward;
        uint16 quorumBps;
        uint16 verificationBps;
        uint64 responseWindowSec;
        uint64 jailDurationSec;

        (
            validStake,
            invalidStake,
            errorStake,
            totalRespondedStake,
            committeeTotalStake,
            committeeSize,
            snapshotId,
            committeeRoot,
            startedAt,
            deadline,
            finalized,
            stakingOps,
            selector,
            slashing,
            reward,
            quorumBps,
            verificationBps,
            responseWindowSec,
            jailDurationSec
        ) = manager.rounds(heartbeatKey, round);
    }

    function test_validThreshold_rewards_jailing_and_claim() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);
        _fundRewards(1e18);

        (bytes32 heartbeatKey, uint8 round,,, address[] memory members) = _submitRawHTXAndGetRound();
        address voter = members[0];
        address nonvoter = members[1];

        _vote(heartbeatKey, round, members, voter, 1);
        _finalizeDefault(heartbeatKey, round);

        assertEq(uint8(manager.roundOutcome(heartbeatKey, round)), uint8(ISlashingPolicy.Outcome.ValidThreshold));

        (HeartbeatManager.HeartbeatStatus status,) = _heartbeatStatus(heartbeatKey);
        assertEq(uint8(status), uint8(HeartbeatManager.HeartbeatStatus.Verified));

        address[] memory voters = new address[](1);
        voters[0] = voter;
        manager.distributeRewards(heartbeatKey, round, voters);
        assertGt(rewardPolicy.rewards(voter), 0);

        uint256 rewardBefore = rewardToken.balanceOf(voter);
        vm.prank(voter);
        rewardPolicy.claim();
        assertGt(rewardToken.balanceOf(voter), rewardBefore);

        jailingPolicy.recordRound(heartbeatKey, round);
        jailingPolicy.enforceJailFromMembers(heartbeatKey, round, members);
        assertTrue(stakingOps.isJailed(nonvoter));
    }

    function test_invalidThreshold_noBondRefund() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);
        _fundRewards(1e18);

        (bytes32 heartbeatKey, uint8 round,,, address[] memory members) = _submitRawHTXAndGetRound();
        address voter = members[0];

        _vote(heartbeatKey, round, members, voter, 2);
        uint256 balanceBefore = stakeToken.balanceOf(ops[0]);
        _finalizeDefault(heartbeatKey, round);

        assertEq(uint8(manager.roundOutcome(heartbeatKey, round)), uint8(ISlashingPolicy.Outcome.InvalidThreshold));

        (HeartbeatManager.HeartbeatStatus status,) = _heartbeatStatus(heartbeatKey);
        assertEq(uint8(status), uint8(HeartbeatManager.HeartbeatStatus.Invalid));
        assertEq(stakeToken.balanceOf(ops[0]), balanceBefore);
    }

    function test_noQuorum_expires() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 6_000, 8_000, 10, 100, 0);

        (bytes32 heartbeatKey, uint8 round,,,) = _submitRawHTXAndGetRound();
        _finalizeDefault(heartbeatKey, round);

        (HeartbeatManager.HeartbeatStatus status,) = _heartbeatStatus(heartbeatKey);
        assertEq(uint8(status), uint8(HeartbeatManager.HeartbeatStatus.Expired));
        assertEq(uint8(manager.roundOutcome(heartbeatKey, round)), uint8(ISlashingPolicy.Outcome.Inconclusive));
    }

    function test_escalation_then_finalizes() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 1);

        (bytes32 heartbeatKey, uint8 round,,,) = _submitRawHTXAndGetRound();
        _finalizeDefault(heartbeatKey, round);

        (HeartbeatManager.HeartbeatStatus status, uint8 currentRound) = _heartbeatStatus(heartbeatKey);
        assertEq(uint8(status), uint8(HeartbeatManager.HeartbeatStatus.Pending));
        assertEq(currentRound, 2);

        (uint32 committeeSize, uint64 snapshotId, bytes32 committeeRoot,) = _roundMeta(heartbeatKey, 2);
        assertTrue(committeeRoot != bytes32(0));

        address[] memory members2 = selector.selectCommittee(heartbeatKey, 2, committeeSize, snapshotId);
        _sortMembers(members2);

        _vote(heartbeatKey, 2, members2, members2[0], 1);
        _vote(heartbeatKey, 2, members2, members2[1], 1);
        _finalizeRound(heartbeatKey, 2, 1);

        (HeartbeatManager.HeartbeatStatus status2,) = _heartbeatStatus(heartbeatKey);
        assertEq(uint8(status2), uint8(HeartbeatManager.HeartbeatStatus.Verified));
    }

    function test_exhausted_escalations_expires() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 1);

        (bytes32 heartbeatKey, uint8 round,,,) = _submitRawHTXAndGetRound();
        _finalizeDefault(heartbeatKey, round);
        _finalizeRound(heartbeatKey, 2, 1);

        (HeartbeatManager.HeartbeatStatus status,) = _heartbeatStatus(heartbeatKey);
        assertEq(uint8(status), uint8(HeartbeatManager.HeartbeatStatus.Expired));
    }

    function test_reward_budget_empty_reverts() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);

        (bytes32 heartbeatKey, uint8 round,,, address[] memory members) = _submitRawHTXAndGetRound();
        _vote(heartbeatKey, round, members, members[0], 1);
        _finalizeDefault(heartbeatKey, round);

        address[] memory voters = new address[](1);
        voters[0] = members[0];

        vm.expectRevert(RewardPolicy.InsufficientBudget.selector);
        manager.distributeRewards(heartbeatKey, round, voters);
    }

    function test_accounting_freeze_blocks_rewards() public {
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = 2e18;

        _deploySystem(1, stakes, 1, 1, 5_000, 5_000, 10, 100, 0);

        uint256 slot = stdstore.target(address(rewardPolicy)).sig("accountingFrozen()").find();
        vm.store(address(rewardPolicy), bytes32(slot), bytes32(uint256(1)));

        address[] memory recipients = new address[](1);
        recipients[0] = ops[0];
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;

        vm.expectRevert(RewardPolicy.AccountingFrozen.selector);
        vm.prank(address(manager));
        rewardPolicy.accrueWeights(bytes32("hb"), 1, recipients, weights);
    }

    function test_reward_weight_mismatch_reverts() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);
        _fundRewards(1e18);

        (bytes32 heartbeatKey, uint8 round,,, address[] memory members) = _submitRawHTXAndGetRound();
        _vote(heartbeatKey, round, members, members[0], 1);
        _finalizeDefault(heartbeatKey, round);

        address[] memory voters = new address[](1);
        voters[0] = members[1]; // non-voter

        vm.expectRevert(HeartbeatManager.InvalidVoterInList.selector);
        manager.distributeRewards(heartbeatKey, round, voters);
    }

    function test_duplicate_reward_processing_reverts() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);
        _fundRewards(1e18);

        (bytes32 heartbeatKey, uint8 round,,, address[] memory members) = _submitRawHTXAndGetRound();
        _vote(heartbeatKey, round, members, members[0], 1);
        _finalizeDefault(heartbeatKey, round);

        address[] memory voters = new address[](1);
        voters[0] = members[0];
        manager.distributeRewards(heartbeatKey, round, voters);

        vm.expectRevert(HeartbeatManager.RewardsAlreadyDone.selector);
        manager.distributeRewards(heartbeatKey, round, voters);
    }

    function test_jailing_idempotent() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);
        _fundRewards(1e18);

        (bytes32 heartbeatKey, uint8 round,,, address[] memory members) = _submitRawHTXAndGetRound();
        _vote(heartbeatKey, round, members, members[0], 1);
        _finalizeDefault(heartbeatKey, round);

        jailingPolicy.recordRound(heartbeatKey, round);
        jailingPolicy.enforceJailFromMembers(heartbeatKey, round, members);
        jailingPolicy.enforceJailFromMembers(heartbeatKey, round, members);

        assertTrue(stakingOps.isJailed(members[1]));
    }

    function test_slashing_callback_failure_keeps_notified_false() public {
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = 2e18;

        _deploySystem(1, stakes, 1, 1, 5_000, 5_000, 10, 100, 0);

        RevertingSlashingPolicy reverter = new RevertingSlashingPolicy();
        config.setModules(address(stakingOps), address(selector), address(reverter), address(rewardPolicy));

        (bytes32 heartbeatKey, uint8 round,,, address[] memory members) = _submitRawHTXAndGetRound();
        _vote(heartbeatKey, round, members, members[0], 1);
        _finalizeDefault(heartbeatKey, round);

        assertFalse(manager.slashingNotified(heartbeatKey, round));
        manager.retrySlashing(heartbeatKey, round);
        assertFalse(manager.slashingNotified(heartbeatKey, round));
    }

    function test_slashing_gas_limit_too_low_fails_callback() public {
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = 2e18;

        _deploySystem(1, stakes, 1, 1, 5_000, 5_000, 10, 100, 0);
        manager.setSlashingGasLimit(1);

        (bytes32 heartbeatKey, uint8 round,,, address[] memory members) = _submitRawHTXAndGetRound();
        _vote(heartbeatKey, round, members, members[0], 1);
        _finalizeDefault(heartbeatKey, round);

        assertFalse(manager.slashingNotified(heartbeatKey, round));
    }

    function test_bad_raw_htx_reverts() public {
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = 2e18;

        _deploySystem(1, stakes, 1, 1, 5_000, 5_000, 10, 100, 0);

        (bytes32 heartbeatKey, uint8 round,,,) = _submitRawHTXAndGetRound();

        (,,, uint64 deadline) = _roundMeta(heartbeatKey, round);
        vm.warp(uint256(deadline) + 1);

        vm.expectRevert(HeartbeatManager.RawHTXHashMismatch.selector);
        manager.escalateOrExpire(heartbeatKey, _defaultRawHTX(2));
    }

    function test_member_proof_invalid_reverts() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);

        (bytes32 heartbeatKey, uint8 round,,, address[] memory members) = _submitRawHTXAndGetRound();
        bytes32[] memory wrongProof = _proofForMember(heartbeatKey, round, members, members[0]);

        vm.expectRevert(HeartbeatManager.NotInCommittee.selector);
        vm.prank(members[1]);
        manager.submitVerdict(heartbeatKey, 1, wrongProof);
    }

    function test_snapshot_edge_reverts() public {
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = 2e18;

        _deploySystem(1, stakes, 1, 1, 5_000, 5_000, 10, 100, 0);

        bytes memory raw = _defaultRawHTX(1);

        vm.expectRevert(abi.encodeWithSelector(HeartbeatManager.SnapshotBlockUnavailable.selector, uint64(0)));
        vm.prank(ops[0]);
        manager.submitHeartbeat(raw, 0);

        uint64 snapshotId = uint64(block.number);
        vm.expectRevert(abi.encodeWithSelector(HeartbeatManager.SnapshotBlockUnavailable.selector, snapshotId));
        vm.prank(ops[0]);
        manager.submitHeartbeat(raw, snapshotId);
    }

    function test_min_committee_vp_reverts() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);

        vm.prank(admin);
        selector.setMinCommitteeVP(10e18);

        bytes32 heartbeatKey = keccak256("hb");
        uint64 snapshotId = uint64(block.number - 1);

        uint32 committeeSize = config.baseCommitteeSize();
        uint256 totalStake = stakes[0] + stakes[1];
        vm.expectRevert(
            abi.encodeWithSelector(WeightedCommitteeSelector.InsufficientCommitteeVP.selector, totalStake, 10e18)
        );
        selector.selectCommittee(heartbeatKey, 1, committeeSize, snapshotId);
    }

    function test_min_stake_deactivates_operator() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);

        config.setParams(
            config.baseCommitteeSize(),
            config.committeeSizeGrowthBps(),
            config.maxCommitteeSize(),
            config.maxEscalations(),
            config.quorumBps(),
            config.verificationBps(),
            config.responseWindow(),
            config.jailDuration(),
            config.maxVoteBatchSize(),
            10e18
        );

        stakingOps.pokeActiveMany(ops);

        address[] memory active = stakingOps.getActiveOperators();
        assertEq(active.length, 0);

        bytes32 heartbeatKey = keccak256("hb2");
        uint64 snapshotId = uint64(block.number - 1);

        uint32 committeeSize = config.baseCommitteeSize();
        vm.expectRevert(WeightedCommitteeSelector.NoOperators.selector);
        selector.selectCommittee(heartbeatKey, 1, committeeSize, snapshotId);
    }

    function test_jailed_operator_inactive() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 2e18;
        stakes[1] = 2e18;

        _deploySystem(2, stakes, 2, 2, 5_000, 5_000, 10, 100, 0);

        vm.prank(address(jailingPolicy));
        stakingOps.jail(ops[0], uint64(block.timestamp + 100));

        stakingOps.pokeActive(ops[0]);
        assertFalse(stakingOps.isActiveOperator(ops[0]));
    }
}
