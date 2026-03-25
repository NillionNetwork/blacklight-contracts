// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Interfaces.sol";

/// @title NodeOperator
/// @notice Manages a single pre-provisioned node address and delegates staking/reward
///         operations on behalf of a user.
contract NodeOperator is INodeOperator, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error ContractNotConfigured();
    error InsufficientStake();
    error BelowMinimumStake();
    error FeeTooHigh();
    error InvalidUserAssignment();
    error TokenMismatch();
    error CannotRescueActiveToken();
    error NodeJailed();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event NodeAssigned(address indexed user, address indexed node);

    event Staked(address indexed user, uint256 amount, address indexed node);
    event UnstakeRequested(address indexed user, uint256 amount, address indexed node);
    event UnstakedWithdrawn(address indexed user, uint256 amount, address indexed node);
    event RewardsHarvested(uint256 totalHarvested, uint256 fee);
    event RewardsClaimed(address indexed user, uint256 amount);
    event FeesCollected(uint256 amount);
    event ModeFeeBpsUpdated(
        uint256 oldWithdrawBps, uint256 newWithdrawBps, uint256 oldRestakeBps, uint256 newRestakeBps
    );
    event RewardBehaviorUpdated(address indexed user, uint8 oldBehavior, uint8 newBehavior);
    event RewardsRestaked(address indexed user, uint256 amount, uint256 fee, address indexed node);
    event StakingOperatorsUpdated(address oldAddress, address newAddress);
    event RewardPolicyUpdated(address oldAddress, address newAddress);
    event TokenUpdated(address oldAddress, address newAddress);
    event MinStakeUpdated(uint256 oldMinStake, uint256 newMinStake);
    event TokensRescued(address indexed tokenAddress, address indexed to, uint256 amount);

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    uint256 public constant MAX_FEE_BPS = 5000; // hard cap: 50%

    // ──────────────────────────────────────────────
    // Configurable limits
    // ──────────────────────────────────────────────

    uint256 public minStake; // owner-settable minimum first-stake amount

    // ──────────────────────────────────────────────
    // Configurable addresses
    // ──────────────────────────────────────────────

    IStakingOperators public stakingOperators;
    IRewardPolicyExtended public rewardPolicy;
    IERC20 public token;

    // ──────────────────────────────────────────────
    // Internal state
    // ──────────────────────────────────────────────

    address public immutable nodeAddress;
    address public nodeUser;

    // ──────────────────────────────────────────────
    // Fee management
    // ──────────────────────────────────────────────

    RewardBehavior private _rewardBehavior;
    uint256 public override withdrawFeeBps;
    uint256 public override restakeFeeBps;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address owner_,
        uint256 minStake_,
        address nodeAddress_,
        address stakingOperators_,
        address rewardPolicy_,
        address token_,
        uint256 withdrawFeeBps_,
        uint256 restakeFeeBps_
    ) Ownable(owner_) {
        if (nodeAddress_ == address(0)) revert ZeroAddress();
        if (withdrawFeeBps_ > MAX_FEE_BPS || restakeFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (token_ != address(0)) {
            if (
                stakingOperators_ != address(0)
                    && IStakingOperators(stakingOperators_).stakingToken() != token_
            ) revert TokenMismatch();
            if (
                rewardPolicy_ != address(0)
                    && IRewardPolicyExtended(rewardPolicy_).rewardToken() != token_
            ) revert TokenMismatch();
        }
        minStake = minStake_;
        stakingOperators = IStakingOperators(stakingOperators_);
        rewardPolicy = IRewardPolicyExtended(rewardPolicy_);
        token = IERC20(token_);
        withdrawFeeBps = withdrawFeeBps_;
        restakeFeeBps = restakeFeeBps_;
        _rewardBehavior = RewardBehavior.AutoRestake;
        nodeAddress = nodeAddress_;
    }

    // ──────────────────────────────────────────────
    // Configuration (onlyOwner)
    // ──────────────────────────────────────────────

    function setStakingOperators(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        token.forceApprove(address(stakingOperators), 0);
        emit StakingOperatorsUpdated(address(stakingOperators), addr);
        stakingOperators = IStakingOperators(addr);
    }

    function setRewardPolicy(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        emit RewardPolicyUpdated(address(rewardPolicy), addr);
        rewardPolicy = IRewardPolicyExtended(addr);
    }

    function setToken(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        if (stakingOperators.stakingToken() != addr) revert TokenMismatch();
        if (rewardPolicy.rewardToken() != addr) revert TokenMismatch();

        token.forceApprove(address(stakingOperators), 0);
        emit TokenUpdated(address(token), addr);
        token = IERC20(addr);
    }

    function setModeFeeBps(uint256 withdrawBps, uint256 restakeBps) external override onlyOwner {
        if (withdrawBps > MAX_FEE_BPS || restakeBps > MAX_FEE_BPS) revert FeeTooHigh();

        emit ModeFeeBpsUpdated(withdrawFeeBps, withdrawBps, restakeFeeBps, restakeBps);
        withdrawFeeBps = withdrawBps;
        restakeFeeBps = restakeBps;
    }

    function setMinStake(uint256 newMinStake) external onlyOwner {
        emit MinStakeUpdated(minStake, newMinStake);
        minStake = newMinStake;
    }

    /// @notice Rescues ERC-20 tokens stranded in this contract after a token migration.
    /// @dev Cannot rescue the currently active token to prevent interference with staking flows.
    function rescueTokens(IERC20 rescueToken, address to, uint256 amount) external onlyOwner {
        if (address(rescueToken) == address(token)) revert CannotRescueActiveToken();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        rescueToken.safeTransfer(to, amount);
        emit TokensRescued(address(rescueToken), to, amount);
    }

    // ──────────────────────────────────────────────
    // Internal node management
    // ──────────────────────────────────────────────

    function _assignNode(address user) internal {
        nodeUser = user;
        _rewardBehavior = RewardBehavior.AutoRestake;
        emit NodeAssigned(user, nodeAddress);
    }


    function _ensureStakeConfigured() internal view {
        if (address(stakingOperators) == address(0) || address(token) == address(0)) {
            revert ContractNotConfigured();
        }
    }

    function _ensureRewardConfigured() internal view {
        if (address(rewardPolicy) == address(0) || address(token) == address(0)) {
            revert ContractNotConfigured();
        }
    }

    // ──────────────────────────────────────────────
    // Factory-routed operations
    // ──────────────────────────────────────────────

    function stake() external override nonReentrant onlyOwner {
        if (nodeUser == address(0)) revert ZeroAddress();
        _ensureStakeConfigured();
        if (stakingOperators.isJailed(nodeAddress)) revert NodeJailed();

        // Use actual balance to support fee-on-transfer tokens
        uint256 available = token.balanceOf(address(this));
        if (available == 0) revert ZeroAmount();

        uint256 currentStake = stakingOperators.stakeOf(nodeAddress);
        if (currentStake + available < minStake) revert BelowMinimumStake();

        token.forceApprove(address(stakingOperators), available);
        stakingOperators.stakeTo(nodeAddress, available);

        emit Staked(nodeUser, available, nodeAddress);
    }

    /// @notice Requests to unstake a portion of the node's stake.
    /// @param amount The amount of stake to unstake (must be less than the current stake).
    /// @dev Unstaking below minStake will revert except when the remaining stake is 0.
    function requestUnstake(uint256 amount) external override nonReentrant onlyOwner {
        if (nodeUser == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _ensureStakeConfigured();

        uint256 currentStake = stakingOperators.stakeOf(nodeAddress);
        if (amount > currentStake) revert InsufficientStake();

        uint256 remaining = currentStake - amount;
        if (remaining != 0 && remaining < minStake) revert BelowMinimumStake();

        stakingOperators.requestUnstake(nodeAddress, amount);

        // If fully exiting, force rewards to withdraw mode
        if (stakingOperators.stakeOf(nodeAddress) == 0){
            _rewardBehavior = RewardBehavior.WithdrawToUser;
        }

        emit UnstakeRequested(nodeUser, amount, nodeAddress);
    }

    /// @notice Withdraws the unstaked stake from the node.
    /// @dev Withdrawing will revert if the node has no pending unstake.
    function withdrawUnstaked() external override nonReentrant onlyOwner {
        if (nodeUser == address(0)) revert ZeroAddress();
        _ensureStakeConfigured();

        uint256 balBefore = token.balanceOf(address(this));
        stakingOperators.withdrawUnstaked(nodeAddress);
        uint256 balAfter = token.balanceOf(address(this));
        uint256 withdrawn;
        unchecked {
            withdrawn = balAfter - balBefore;
        }

        if (withdrawn > 0) {
            token.safeTransfer(nodeUser, withdrawn);
        }

        emit UnstakedWithdrawn(nodeUser, withdrawn, nodeAddress);
    }

    /// @dev Distributes the entire token balance (claimed + any direct transfers).
    ///      This sweep-all design is intentional so that tokens arriving via any mechanism
    ///      are properly distributed rather than locked.
    function harvestRewards() external override nonReentrant onlyOwner {
        _harvestRewards();
    }

    function _harvestRewards() internal {
        _ensureRewardConfigured();
        if (nodeUser == address(0)) revert ZeroAddress();
        _claimRewards();
        uint256 harvestable = token.balanceOf(address(this));
        _harvestIfPossible(harvestable);
    }

    function setRewardBehavior(RewardBehavior behavior) external override onlyOwner {

        // Prevent re-enabling AutoRestake on a fully-exited operator
        if (behavior == RewardBehavior.AutoRestake && stakingOperators.stakeOf(nodeAddress) == 0) {
            revert BelowMinimumStake();
        }

        RewardBehavior oldBehavior = _rewardBehavior;
        _rewardBehavior = behavior;
        emit RewardBehaviorUpdated(nodeUser, uint8(oldBehavior), uint8(behavior));
    }


    /// @dev No-op if `user` is already assigned; reverts if a different user is bound.
    function assignUser(address user) external override onlyOwner {
        if (user == address(0)) revert ZeroAddress();
        if (nodeUser != address(0) && nodeUser != user) revert InvalidUserAssignment();
        if (nodeUser == address(0)) {
            _assignNode(user);
        }
    }

    function _claimRewards() internal {
        uint256 available = rewardPolicy.rewards(address(this));
        if (available == 0) return;

        uint256 balBefore = token.balanceOf(address(this));
        rewardPolicy.claim();
        uint256 balAfter = token.balanceOf(address(this));
        uint256 claimed;
        unchecked {
            claimed = balAfter - balBefore;
        }
        if (claimed == 0) return;

        emit RewardsClaimed(nodeUser, claimed);
    }

    // ──────────────────────────────────────────────
    // Internal reward logic
    // ──────────────────────────────────────────────

    function _harvestIfPossible(uint256 harvestableRewards) internal {
        if (harvestableRewards == 0) return;

        _ensureStakeConfigured();
        // Jailed nodes cannot restake; treat as withdraw so the correct fee applies
        bool restake = _rewardBehavior == RewardBehavior.AutoRestake
            && !stakingOperators.isJailed(nodeAddress);
        uint256 feeBpsToUse = restake ? restakeFeeBps : withdrawFeeBps;
        uint256 fee = (harvestableRewards * feeBpsToUse) / 10000;
        // Fees are sent to owner() which is the NodeOperatorFactory; the factory
        // accumulates them and the admin can withdraw via Factory.withdrawFees().
        if (fee != 0) token.safeTransfer(owner(), fee);
        emit FeesCollected(fee);

        uint256 net;
        unchecked {
            net = harvestableRewards - fee;
        }

        if (!restake) {
            if (net != 0) token.safeTransfer(nodeUser, net);
            emit RewardsHarvested(net, fee);
            return;
        }

        if (net != 0) {
            token.forceApprove(address(stakingOperators), net);
            stakingOperators.stakeTo(nodeAddress, net);
        }
        emit RewardsRestaked(nodeUser, net, fee, nodeAddress);
    }

    function rewardBehavior() external view override returns (uint8) {
        return uint8(_rewardBehavior);
    }
}
