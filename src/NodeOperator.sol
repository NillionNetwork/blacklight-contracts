// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "./Interfaces.sol";

/// @title NodeOperator
/// @notice Manages a pool of pre-provisioned node addresses and delegates staking/reward
///         operations on behalf of users. Uses a MasterChef-style reward accumulator for
///         fair distribution of pooled rewards, with a configurable fee on harvested rewards.
contract NodeOperator is INodeOperator, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error ContractNotConfigured();
    error InsufficientStake();
    error BelowMinimumStake();
    error NothingToClaim();
    error FeeTooHigh();
    error FactoryOnly();
    error InvalidUserAssignment();
    error InvalidBehavior();
    error RestakeModeUnsupportedTokenPair();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event NodeAssigned(address indexed user, address indexed node);
    event NodeReleased(address indexed user, address indexed node);
    event Staked(address indexed user, uint256 amount, address indexed node);
    event UnstakeRequested(address indexed user, uint256 amount, address indexed node);
    event UnstakedWithdrawn(address indexed user, uint256 amount, address indexed node);
    event RewardsHarvested(uint256 totalHarvested, uint256 fee);
    event RewardsClaimed(address indexed user, uint256 amount);
    event FeesCollected(uint256 amount);
    event ModeFeeBpsUpdated(uint256 oldWithdrawBps, uint256 newWithdrawBps, uint256 oldRestakeBps, uint256 newRestakeBps);
    event RewardBehaviorUpdated(address indexed user, uint8 oldBehavior, uint8 newBehavior);
    event RewardsRestaked(address indexed user, uint256 amount, uint256 fee, address indexed node);
    event StakingOperatorsUpdated(address oldAddress, address newAddress);
    event RewardPolicyUpdated(address oldAddress, address newAddress);
    event StakingTokenUpdated(address oldAddress, address newAddress);
    event RewardTokenUpdated(address oldAddress, address newAddress);
    event MinStakeUpdated(uint256 oldMinStake, uint256 newMinStake);

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    uint256 public constant ABSOLUTE_MAX_FEE_BPS = 10000; // hard cap: 100%

    // ──────────────────────────────────────────────
    // Configurable limits
    // ──────────────────────────────────────────────

    uint256 public minStake; // owner-settable minimum first-stake amount

    // ──────────────────────────────────────────────
    // Router
    // ──────────────────────────────────────────────

    address public immutable routerFactory;

    // ──────────────────────────────────────────────
    // Configurable addresses
    // ──────────────────────────────────────────────

    IStakingOperators public stakingOperators;
    IRewardPolicyExtended public rewardPolicy;
    IERC20 public stakingToken;
    IERC20 public rewardToken;

    // ──────────────────────────────────────────────
    // Internal state
    // ──────────────────────────────────────────────

    address public immutable nodeAddress;
    address public nodeUser;

    // ──────────────────────────────────────────────
    // Fee management
    // ──────────────────────────────────────────────

    enum RewardBehavior {
        WithdrawToUser,
        AutoRestake
    }

    RewardBehavior private _rewardBehavior;
    uint256 public override withdrawFeeBps;
    uint256 public override restakeFeeBps;

    modifier onlyRouterFactory() {
        if (msg.sender != routerFactory) revert FactoryOnly();
        _;
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address owner_,
        uint256 minStake_,
        address routerFactory_,
        address nodeAddress_,
        address stakingOperators_,
        address rewardPolicy_,
        address stakingToken_,
        address rewardToken_
    ) Ownable(owner_) {
        if (routerFactory_ == address(0)) revert ZeroAddress();
        minStake = minStake_;
        routerFactory = routerFactory_;
        stakingOperators = IStakingOperators(stakingOperators_);
        rewardPolicy = IRewardPolicyExtended(rewardPolicy_);
        stakingToken = IERC20(stakingToken_);
        rewardToken = IERC20(rewardToken_);
        nodeAddress = nodeAddress_;
    }

    // ──────────────────────────────────────────────
    // Configuration (onlyOwner)
    // ──────────────────────────────────────────────

    function setStakingOperators(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        emit StakingOperatorsUpdated(address(stakingOperators), addr);
        stakingOperators = IStakingOperators(addr);
    }

    function setRewardPolicy(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        emit RewardPolicyUpdated(address(rewardPolicy), addr);
        rewardPolicy = IRewardPolicyExtended(addr);
    }

    function setStakingToken(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        emit StakingTokenUpdated(address(stakingToken), addr);
        stakingToken = IERC20(addr);
    }

    function setRewardToken(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        emit RewardTokenUpdated(address(rewardToken), addr);
        rewardToken = IERC20(addr);
    }

    function setModeFeeBps(uint256 withdrawBps, uint256 restakeBps) external override onlyOwner {
        if (withdrawBps > ABSOLUTE_MAX_FEE_BPS || restakeBps > ABSOLUTE_MAX_FEE_BPS) revert FeeTooHigh();

        emit ModeFeeBpsUpdated(withdrawFeeBps, withdrawBps, restakeFeeBps, restakeBps);
        withdrawFeeBps = withdrawBps;
        restakeFeeBps = restakeBps;
    }

    function setMinStake(uint256 newMinStake) external onlyOwner {
        emit MinStakeUpdated(minStake, newMinStake);
        minStake = newMinStake;
    }

    // ──────────────────────────────────────────────
    // Internal node management
    // ──────────────────────────────────────────────

    function _assignNode(address user) internal {
        nodeUser = user;
        emit NodeAssigned(user, nodeAddress);
    }

    function _releaseNode() internal {
        address user = nodeUser;
        nodeUser = address(0);
        emit NodeReleased(user, nodeAddress);
    }

    function _ensureStakeConfigured() internal view {
        if (address(stakingOperators) == address(0) || address(stakingToken) == address(0)) {
            revert ContractNotConfigured();
        }
    }

    function _ensureRewardConfigured() internal view {
        if (address(rewardPolicy) == address(0) || address(rewardToken) == address(0)) {
            revert ContractNotConfigured();
        }
    }

    // ──────────────────────────────────────────────
    // Factory-routed operations
    // ──────────────────────────────────────────────

    function stake(uint256 amount) external override nonReentrant onlyRouterFactory {
        if (nodeUser == address(0) || nodeAddress == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _ensureStakeConfigured();

        // Tokens already transferred to this contract by the Factory
        uint256 currentStake = stakingOperators.stakeOf(nodeAddress);
        if (currentStake + amount < minStake) revert BelowMinimumStake();

        stakingToken.forceApprove(address(stakingOperators), amount);
        stakingOperators.stakeTo(nodeAddress, amount);

        emit Staked(nodeUser, amount, nodeAddress);
    }

    function requestUnstake(uint256 amount) external override nonReentrant onlyRouterFactory {
        if (nodeUser == address(0) || nodeAddress == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _ensureStakeConfigured();

        uint256 currentStake = stakingOperators.stakeOf(nodeAddress);
        if (amount > currentStake) revert InsufficientStake();

        stakingOperators.requestUnstake(nodeAddress, amount);

        emit UnstakeRequested(nodeUser, amount, nodeAddress);
    }

    function withdrawUnstaked() external override nonReentrant onlyRouterFactory {
        if (nodeUser == address(0) || nodeAddress == address(0)) revert ZeroAddress();
        _ensureStakeConfigured();

        uint256 balBefore = stakingToken.balanceOf(address(this));
        stakingOperators.withdrawUnstaked(nodeAddress);
        uint256 balAfter = stakingToken.balanceOf(address(this));
        uint256 withdrawn;
        unchecked { withdrawn = balAfter - balBefore; }

        if (withdrawn > 0) {
            stakingToken.safeTransfer(nodeUser, withdrawn);
        }

        emit UnstakedWithdrawn(nodeUser, withdrawn, nodeAddress);
        if (stakingOperators.stakeOf(nodeAddress) == 0) {
            _releaseNode();
        }
    }

    function harvestRewards() external override nonReentrant onlyRouterFactory {
        _ensureRewardConfigured();
        if (nodeUser == address(0) || nodeAddress == address(0)) revert ZeroAddress();
        _claimRewards();
        _harvestIfPossible();
    }

    function setRewardBehavior(uint8 behavior) external override onlyRouterFactory {
        if (behavior > uint8(RewardBehavior.AutoRestake)) revert InvalidBehavior();
        RewardBehavior nextBehavior = RewardBehavior(behavior);
        if (nextBehavior == RewardBehavior.AutoRestake && address(rewardToken) != address(stakingToken)) {
            revert RestakeModeUnsupportedTokenPair();
        }

        RewardBehavior oldBehavior = _rewardBehavior;
        _rewardBehavior = nextBehavior;
        emit RewardBehaviorUpdated(nodeUser, uint8(oldBehavior), behavior);
    }

    function resetRewardBehavior() external override onlyRouterFactory {
        RewardBehavior oldBehavior = _rewardBehavior;
        _rewardBehavior = RewardBehavior.WithdrawToUser;
        emit RewardBehaviorUpdated(nodeUser, uint8(oldBehavior), uint8(RewardBehavior.WithdrawToUser));
    }

    function assignUser(address user) external override onlyRouterFactory {
        if (user == address(0)) revert ZeroAddress();
        if (nodeUser != address(0) && nodeUser != user) revert InvalidUserAssignment();
        if (nodeAddress == address(0)) revert ZeroAddress();
        if (nodeUser == address(0)) {
            _assignNode(user);
        }
    }

    function _claimRewards() internal {
        uint256 available = rewardPolicy.rewards(address(this));
        if (available == 0) return;

        uint256 balBefore = rewardToken.balanceOf(address(this));
        rewardPolicy.claim();
        uint256 balAfter = rewardToken.balanceOf(address(this));
        uint256 claimed;
        unchecked { claimed = balAfter - balBefore; }
        if (claimed == 0) revert NothingToClaim();

        emit RewardsClaimed(nodeUser, claimed);
    }

    // ──────────────────────────────────────────────
    // Internal reward logic
    // ──────────────────────────────────────────────

    function _harvestIfPossible() internal {
        uint256 harvestableRewards = rewardToken.balanceOf(address(this));
        if (harvestableRewards == 0) return;

        bool restake = _rewardBehavior == RewardBehavior.AutoRestake;
        uint256 feeBpsToUse = restake ? restakeFeeBps : withdrawFeeBps;
        uint256 fee = (harvestableRewards * feeBpsToUse) / 10000;
        if (fee != 0) rewardToken.safeTransfer(routerFactory, fee);
        emit FeesCollected(fee);

        uint256 net;
        unchecked { net = harvestableRewards - fee; }

        if (!restake) {
            if (net != 0) rewardToken.safeTransfer(nodeUser, net);
            emit RewardsHarvested(net, fee);
            return;
        }

        if (address(rewardToken) != address(stakingToken)) revert RestakeModeUnsupportedTokenPair();
        _ensureStakeConfigured();

        if (net != 0) {
            stakingToken.forceApprove(address(stakingOperators), net);
            stakingOperators.stakeTo(nodeAddress, net);
        }
        emit RewardsRestaked(nodeUser, net, fee, nodeAddress);
    }

    function rewardBehavior() external view override returns (uint8) {
        return uint8(_rewardBehavior);
    }
}
