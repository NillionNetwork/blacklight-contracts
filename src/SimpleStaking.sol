// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Interfaces.sol";

/// @title SimpleStaking
/// @notice Minimal ERC20 staking contract with configurable minimum stake and unstake delay.
/// @dev Reward integrations are opt-in via a notifier hook that must be configured before staking starts.
contract SimpleStaking is ISimpleStaking, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStake();
    error BelowMinimumStake();
    error NoUnbonding();
    error NotReady();
    error InvalidUnstakeDelay();
    error TooManyTranches();
    error ActiveStakeExists();
    error InvalidSnapshot(uint64 snapshotId);
    error StakeOverflow();

    struct StakeCheckpoint {
        uint64 fromBlock;
        uint192 stake;
    }

    uint256 private constant MIN_DELAY = 1 minutes;
    uint256 private constant MAX_DELAY = 30 days;
    uint256 public constant MAX_TRANCHES_PER_ACCOUNT = 32;

    IERC20 private immutable _stakingToken;
    uint256 public override minStake;
    uint256 public override unstakeDelay;
    address public override rewardNotifier;
    uint256 private _totalStaked;

    mapping(address => uint256) private _stakeOf;
    mapping(address => Tranche[]) private _unbonding;
    mapping(address => StakeCheckpoint[]) private _stakeCheckpoints;
    StakeCheckpoint[] private _totalStakeCheckpoints;

    uint64 public override currentSnapshotId;
    mapping(uint64 => uint64) public override snapshotBlock;

    event Staked(address indexed account, uint256 amount, uint256 newStake);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 releaseTime, uint256 newStake);
    event UnstakedWithdrawn(address indexed account, uint256 amount);
    event MinStakeUpdated(uint256 oldMinStake, uint256 newMinStake);
    event UnstakeDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event RewardNotifierUpdated(address oldNotifier, address newNotifier);
    event SnapshotCreated(uint64 indexed snapshotId, uint64 indexed blockNumber, address indexed caller);

    constructor(IERC20 token_, address owner_, uint256 initialMinStake, uint256 initialUnstakeDelay) Ownable(owner_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        if (initialUnstakeDelay < MIN_DELAY || initialUnstakeDelay > MAX_DELAY) revert InvalidUnstakeDelay();

        _stakingToken = token_;
        minStake = initialMinStake;
        unstakeDelay = initialUnstakeDelay;
    }

    function stakingToken() external view override returns (address) {
        return address(_stakingToken);
    }

    function totalStaked() external view override returns (uint256) {
        return _totalStaked;
    }

    function stakeOf(address account) external view override returns (uint256) {
        return _stakeOf[account];
    }

    function getUnbondingTranches(address account) external view override returns (Tranche[] memory) {
        return _unbonding[account];
    }

    function setMinStake(uint256 newMinStake) external override onlyOwner {
        emit MinStakeUpdated(minStake, newMinStake);
        minStake = newMinStake;
    }

    function setUnstakeDelay(uint256 newDelay) external override onlyOwner {
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert InvalidUnstakeDelay();
        emit UnstakeDelayUpdated(unstakeDelay, newDelay);
        unstakeDelay = newDelay;
    }

    function setRewardNotifier(address newNotifier) external override onlyOwner {
        if (_totalStaked != 0 && rewardNotifier != newNotifier) revert ActiveStakeExists();
        emit RewardNotifierUpdated(rewardNotifier, newNotifier);
        rewardNotifier = newNotifier;
    }

    function stake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 balanceBefore = _stakingToken.balanceOf(address(this));
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = _stakingToken.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();

        uint256 oldStake = _stakeOf[msg.sender];
        uint256 newStake = oldStake + received;
        _requireStakeFloor(newStake);

        _stakeOf[msg.sender] = newStake;
        _totalStaked += received;

        _writeCheckpoint(_stakeCheckpoints[msg.sender], newStake);
        _writeCheckpoint(_totalStakeCheckpoints, _totalStaked);
        _notifyStakeChange(msg.sender, oldStake, newStake);

        emit Staked(msg.sender, received, newStake);
    }

    function requestUnstake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 oldStake = _stakeOf[msg.sender];
        if (oldStake < amount) revert InsufficientStake();

        uint256 newStake = oldStake - amount;
        if (newStake != 0) _requireStakeFloor(newStake);

        _stakeOf[msg.sender] = newStake;
        _totalStaked -= amount;

        uint64 releaseTime = uint64(block.timestamp + unstakeDelay);
        _pushTranche(_unbonding[msg.sender], amount, releaseTime);
        _writeCheckpoint(_stakeCheckpoints[msg.sender], newStake);
        _writeCheckpoint(_totalStakeCheckpoints, _totalStaked);
        _notifyStakeChange(msg.sender, oldStake, newStake);

        emit UnstakeRequested(msg.sender, amount, releaseTime, newStake);
    }

    function withdrawUnstaked() external override nonReentrant {
        Tranche[] storage tranches = _unbonding[msg.sender];
        uint256 len = tranches.length;
        if (len == 0) revert NoUnbonding();

        uint256 payout;
        uint256 writeIndex;
        for (uint256 i = 0; i < len; ++i) {
            Tranche memory tranche = tranches[i];
            if (block.timestamp >= tranche.releaseTime) {
                payout += tranche.amount;
            } else {
                tranches[writeIndex] = tranche;
                ++writeIndex;
            }
        }

        while (tranches.length > writeIndex) tranches.pop();
        if (payout == 0) revert NotReady();

        _stakingToken.safeTransfer(msg.sender, payout);
        emit UnstakedWithdrawn(msg.sender, payout);
    }

    function snapshot() external override returns (uint64 snapshotId) {
        if (block.number <= 1) revert NotReady();
        snapshotId = ++currentSnapshotId;
        uint64 blockNumber = uint64(block.number - 1);
        snapshotBlock[snapshotId] = blockNumber;
        emit SnapshotCreated(snapshotId, blockNumber, msg.sender);
    }

    function stakeAt(address account, uint64 snapshotId) external view override returns (uint256) {
        uint64 blockNumber = snapshotBlock[snapshotId];
        if (blockNumber == 0) revert InvalidSnapshot(snapshotId);
        return _checkpointValueAt(_stakeCheckpoints[account], blockNumber);
    }

    function totalStakedAt(uint64 snapshotId) external view override returns (uint256) {
        uint64 blockNumber = snapshotBlock[snapshotId];
        if (blockNumber == 0) revert InvalidSnapshot(snapshotId);
        return _checkpointValueAt(_totalStakeCheckpoints, blockNumber);
    }

    function _requireStakeFloor(uint256 newStake) internal view {
        uint256 floor = minStake;
        if (floor != 0 && newStake < floor) revert BelowMinimumStake();
    }

    function _notifyStakeChange(address account, uint256 oldStake, uint256 newStake) internal {
        address notifier = rewardNotifier;
        if (notifier != address(0)) {
            ISimpleStakingRewardNotifier(notifier).onStakeBalanceChanged(account, oldStake, newStake);
        }
    }

    function _pushTranche(Tranche[] storage tranches, uint256 amount, uint64 releaseTime) internal {
        uint256 len = tranches.length;
        if (len != 0) {
            Tranche storage last = tranches[len - 1];
            if (last.releaseTime == releaseTime) {
                last.amount += amount;
                return;
            }
        }

        if (len >= MAX_TRANCHES_PER_ACCOUNT) revert TooManyTranches();
        tranches.push(Tranche({amount: amount, releaseTime: releaseTime}));
    }

    function _writeCheckpoint(StakeCheckpoint[] storage checkpoints, uint256 newStake) internal {
        if (newStake > type(uint192).max) revert StakeOverflow();
        StakeCheckpoint memory checkpoint = StakeCheckpoint({fromBlock: uint64(block.number), stake: uint192(newStake)});
        uint256 len = checkpoints.length;
        if (len != 0 && checkpoints[len - 1].fromBlock == checkpoint.fromBlock) {
            checkpoints[len - 1].stake = checkpoint.stake;
        } else {
            checkpoints.push(checkpoint);
        }
    }

    function _checkpointValueAt(StakeCheckpoint[] storage checkpoints, uint64 blockNumber)
        internal
        view
        returns (uint256)
    {
        uint256 len = checkpoints.length;
        if (len == 0) return 0;
        if (checkpoints[0].fromBlock > blockNumber) return 0;

        uint256 high = len - 1;
        if (checkpoints[high].fromBlock <= blockNumber) return checkpoints[high].stake;

        uint256 low = 0;
        while (high > low) {
            uint256 mid = (high + low + 1) / 2;
            if (checkpoints[mid].fromBlock <= blockNumber) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return checkpoints[low].stake;
    }
}
