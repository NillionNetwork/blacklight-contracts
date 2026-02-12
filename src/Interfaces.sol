// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Minimal shared interfaces used by the RC contracts.
/// @dev Keep this file synchronized with the concrete implementations.

interface IRewardPolicy {
    function spendableBudget() external view returns (uint256);
    function accrueWeights(
        bytes32 heartbeatKey,
        uint8 round,
        address[] calldata recipients,
        uint256[] calldata weights
    ) external;
    function claim() external;
}

interface IProtocolConfig {
    // Committee sizing
    function baseCommitteeSize() external view returns (uint32);
    function committeeSizeGrowthBps() external view returns (uint32);
    function maxCommitteeSize() external view returns (uint32);

    // Escalation
    function maxEscalations() external view returns (uint8);

    // Modules
    function stakingOps() external view returns (address);
    function committeeSelector() external view returns (address);
    function slashingPolicy() external view returns (address);
    function rewardPolicy() external view returns (address);

    // Voting / timing params
    function quorumBps() external view returns (uint16);
    function verificationBps() external view returns (uint16);
    function responseWindow() external view returns (uint256);
    function jailDuration() external view returns (uint256);

    // Misc
    function maxVoteBatchSize() external view returns (uint256);
    function minOperatorStake() external view returns (uint256);
    function nodeVersion() external view returns (string memory);
}

interface ISlashingPolicy {
    enum Outcome { Inconclusive, ValidThreshold, InvalidThreshold }

    function onRoundFinalized(
        bytes32 heartbeatKey,
        uint8 round,
        Outcome outcome,
        bytes32 committeeRoot,
        uint32 committeeSize
    ) external;
}

interface ICommitteeSelector {
    function selectCommittee(
        bytes32 heartbeatKey,
        uint8 round,
        uint32 committeeSize,
        uint64 snapshotId
    ) external view returns (address[] memory members);
}

interface IStakingOperators {
    struct Tranche { uint256 amount; uint64 releaseTime; }
    struct OperatorInfo { bool active; string metadataURI; }

    function unstakeDelay() external view returns (uint256);
    function heartbeatManager() external view returns (address);
    function operatorStaker(address operator) external view returns (address);

    function setSnapshotter(address newSnapshotter) external;
    function setHeartbeatManager(address newHeartbeatManager) external;

    function snapshot() external returns (uint64 snapshotId);
    function stakeAt(address operator, uint64 snapshotId) external view returns (uint256);

    function stakingToken() external view returns (address);
    function stakeOf(address operator) external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function isJailed(address operator) external view returns (bool);

    function getActiveOperators() external view returns (address[] memory);
    function isActiveOperator(address operator) external view returns (bool);

    function getOperatorInfo(address operator) external view returns (OperatorInfo memory);

    function stakeTo(address operator, uint256 amount) external;
    function requestUnstake(address operator, uint256 amount) external;
    function withdrawUnstaked(address operator) external;

    function registerOperator(string calldata metadataURI) external;
    function deactivateOperator() external;
    function reactivateOperator() external;

    function slash(address operator, uint256 amount) external;
    function jail(address operator, uint64 untilTimestamp) external;
}

interface IValidationRegistry {
    function onHeartbeatFinalized(
        bytes32 rawHTXHash,
        uint8 response,
        bytes32 heartbeatKey
    ) external;
}

interface IRewardPolicyExtended is IRewardPolicy {
    function rewards(address account) external view returns (uint256);
    function rewardToken() external view returns (address);
}

interface INodeOperator {
    function setRewardBehavior(uint8 behavior) external;
    function resetRewardBehavior() external;
    function setModeFeeBps(uint256 withdrawBps, uint256 restakeBps) external;

    function assignUser(address user) external;
    function harvestRewards() external;

    function stake(uint256 amount) external;
    function requestUnstake(uint256 amount) external;
    function withdrawUnstaked() external;
    function nodeAddress() external view returns (address);
    function nodeUser() external view returns (address);
    function rewardBehavior() external view returns (uint8);
    function withdrawFeeBps() external view returns (uint256);
    function restakeFeeBps() external view returns (uint256);
    function minStake() external view returns (uint256);
}
