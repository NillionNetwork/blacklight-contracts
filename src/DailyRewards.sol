// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./Interfaces.sol";

/// @title DailyRewards
/// @notice Daily checkpointed rewards stream backed by simple stake shares.
/// @dev Rewards unlock linearly over `epochDuration`, but become claimable only after a daily checkpoint.
contract DailyRewards is IDailyEpochRewards, Ownable, ReentrancyGuard, ISimpleStakingRewardNotifier {
    using SafeERC20 for IERC20;

    uint256 public constant ACC_PRECISION = 1e18;
    uint256 public constant CHECKPOINT_INTERVAL = 1 days;

    error ZeroAddress();
    error ZeroEpochDuration();
    error NothingToClaim();
    error NothingToCheckpoint();
    error AlreadyCheckpointed(uint64 currentDay, uint64 lastDay);
    error NotStaking();
    error UnsupportedAccrual();
    error StakeSyncMismatch(uint256 trackedStake, uint256 providedStake);

    struct UserRewards {
        uint256 pending;
        uint256 rewardPerSharePaid;
        uint256 trackedStake;
    }

    struct DailyCheckpoint {
        uint64 snapshotId;
        uint256 amount;
        uint256 totalStaked;
    }

    IERC20 private immutable _rewardToken;
    ISimpleStaking private immutable _staking;

    uint256 public accountedBalance;
    uint256 private _spendableBudget;
    uint64 public lastUpdate;

    uint256 public streamRemaining;
    uint256 public streamRatePerSecondWad;
    uint64 public streamEnd;

    uint256 public override epochDuration;
    uint64 public override lastCheckpointDay;
    uint256 public accRewardPerShareWad;
    uint256 public totalOutstandingRewards;

    mapping(address => UserRewards) private _userRewards;
    mapping(uint64 => DailyCheckpoint) public checkpoints;

    event Synced(uint256 newAmount, uint256 accountedBalance);
    event StreamUpdated(uint256 streamRemaining, uint256 streamRatePerSecondWad, uint64 streamEnd);
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event CheckpointCreated(
        uint64 indexed day, uint64 indexed snapshotId, uint256 amount, uint256 totalStaked, uint256 accRewardPerShareWad
    );
    event CheckpointCarriedForward(uint64 indexed day, uint64 indexed snapshotId, uint256 amount, uint256 totalStaked);
    event RewardClaimed(address indexed account, uint256 amount);
    event StakeTracked(address indexed account, uint256 oldStake, uint256 newStake);

    constructor(IERC20 rewardToken_, ISimpleStaking staking_, address owner_, uint256 epochDuration_) Ownable(owner_) {
        if (address(rewardToken_) == address(0)) revert ZeroAddress();
        if (address(staking_) == address(0)) revert ZeroAddress();
        if (epochDuration_ == 0) revert ZeroEpochDuration();

        _rewardToken = rewardToken_;
        _staking = staking_;
        epochDuration = epochDuration_;

        sync();
    }

    function rewardToken() external view override returns (address) {
        return address(_rewardToken);
    }

    function staking() external view override returns (address) {
        return address(_staking);
    }

    function spendableBudget() external view override returns (uint256) {
        return _spendableBudget;
    }

    function rewards(address account) public view returns (uint256) {
        UserRewards storage user = _userRewards[account];
        uint256 pending = user.pending;
        uint256 trackedStake = user.trackedStake;
        uint256 paid = user.rewardPerSharePaid;
        uint256 currentAcc = accRewardPerShareWad;
        if (trackedStake == 0 || currentAcc == paid) return pending;
        return pending + Math.mulDiv(trackedStake, currentAcc - paid, ACC_PRECISION);
    }

    function sync() public override {
        _updateUnlock();

        uint256 balance = _rewardToken.balanceOf(address(this));
        if (balance <= accountedBalance) {
            accountedBalance = balance;
            return;
        }

        uint256 delta = balance - accountedBalance;
        accountedBalance = balance;
        _onNewDeposit(delta);
        emit Synced(delta, accountedBalance);
    }

    function checkpoint() external override returns (uint64 day, uint64 snapshotId, uint256 amount) {
        sync();

        day = uint64(block.timestamp / CHECKPOINT_INTERVAL);
        if (day <= lastCheckpointDay) revert AlreadyCheckpointed(day, lastCheckpointDay);

        amount = _spendableBudget;
        if (amount == 0) revert NothingToCheckpoint();

        lastCheckpointDay = day;
        snapshotId = _staking.snapshot();

        uint256 totalStake = _staking.totalStaked();
        if (totalStake == 0) {
            emit CheckpointCarriedForward(day, snapshotId, amount, 0);
            return (day, snapshotId, 0);
        }

        uint256 deltaAcc = Math.mulDiv(amount, ACC_PRECISION, totalStake);
        if (deltaAcc == 0) {
            emit CheckpointCarriedForward(day, snapshotId, amount, totalStake);
            return (day, snapshotId, 0);
        }

        uint256 distributed = Math.mulDiv(totalStake, deltaAcc, ACC_PRECISION);
        _spendableBudget -= distributed;
        accRewardPerShareWad += deltaAcc;
        totalOutstandingRewards += distributed;
        checkpoints[day] = DailyCheckpoint({snapshotId: snapshotId, amount: distributed, totalStaked: totalStake});

        emit CheckpointCreated(day, snapshotId, distributed, totalStake, accRewardPerShareWad);
        return (day, snapshotId, distributed);
    }

    function claim() external override nonReentrant {
        UserRewards storage user = _userRewards[msg.sender];
        _settle(user);

        uint256 amount = user.pending;
        if (amount == 0) revert NothingToClaim();

        user.pending = 0;
        totalOutstandingRewards -= amount;
        _rewardToken.safeTransfer(msg.sender, amount);
        accountedBalance = _rewardToken.balanceOf(address(this));

        emit RewardClaimed(msg.sender, amount);
    }

    function accrueWeights(bytes32, uint8, address[] calldata, uint256[] calldata) external pure override {
        revert UnsupportedAccrual();
    }

    function onStakeBalanceChanged(address account, uint256 oldStake, uint256 newStake) external override {
        if (msg.sender != address(_staking)) revert NotStaking();

        UserRewards storage user = _userRewards[account];
        if (user.trackedStake != oldStake) revert StakeSyncMismatch(user.trackedStake, oldStake);

        _settle(user);
        user.trackedStake = newStake;

        emit StakeTracked(account, oldStake, newStake);
    }

    function setEpochDuration(uint256 newDuration) external onlyOwner {
        if (newDuration == 0) revert ZeroEpochDuration();
        sync();
        emit EpochDurationUpdated(epochDuration, newDuration);
        epochDuration = newDuration;
        _recomputeStreamRate();
    }

    function _settle(UserRewards storage user) internal {
        uint256 trackedStake = user.trackedStake;
        uint256 currentAcc = accRewardPerShareWad;
        uint256 paid = user.rewardPerSharePaid;
        if (trackedStake != 0 && currentAcc != paid) {
            user.pending += Math.mulDiv(trackedStake, currentAcc - paid, ACC_PRECISION);
        }
        user.rewardPerSharePaid = currentAcc;
    }

    function _updateUnlock() internal {
        uint64 nowTs = uint64(block.timestamp);
        uint64 last = lastUpdate;
        if (last == 0) {
            lastUpdate = nowTs;
            return;
        }
        if (nowTs <= last) return;
        if (streamRemaining == 0) {
            lastUpdate = nowTs;
            return;
        }

        uint256 elapsed = uint256(nowTs - last);
        if (streamRatePerSecondWad != 0) {
            uint256 unlocked = Math.mulDiv(elapsed, streamRatePerSecondWad, 1e18);
            if (unlocked > streamRemaining) unlocked = streamRemaining;
            if (unlocked != 0) {
                streamRemaining -= unlocked;
                _spendableBudget += unlocked;
            }
        }

        if (nowTs >= streamEnd && streamRemaining != 0) {
            _spendableBudget += streamRemaining;
            streamRemaining = 0;
            streamRatePerSecondWad = 0;
        }

        lastUpdate = nowTs;
    }

    function _onNewDeposit(uint256 amount) internal {
        if (amount == 0) return;
        streamRemaining += amount;
        _recomputeStreamRate();
    }

    function _recomputeStreamRate() internal {
        if (streamRemaining == 0) {
            streamRatePerSecondWad = 0;
            streamEnd = uint64(block.timestamp);
            emit StreamUpdated(streamRemaining, streamRatePerSecondWad, streamEnd);
            return;
        }

        uint64 nowTs = uint64(block.timestamp);
        if (streamEnd > nowTs) {
            uint256 remainingTime = uint256(streamEnd - nowTs);
            if (remainingTime == 0) remainingTime = 1;
            streamRatePerSecondWad = Math.mulDiv(streamRemaining, 1e18, remainingTime);
        } else {
            streamEnd = uint64(nowTs + epochDuration);
            streamRatePerSecondWad = Math.mulDiv(streamRemaining, 1e18, epochDuration);
        }

        emit StreamUpdated(streamRemaining, streamRatePerSecondWad, streamEnd);
    }
}
