// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./NodeOperator.sol";
import "./Interfaces.sol";

/// @title NodeOperatorFactory
/// @notice Node registry that auto-deploys NodeOperator instances and auto-binds
///         users to free nodes on their first stake. Users approve only this contract.
contract NodeOperatorFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error ZeroAddress();
    error NoBoundNodeOperator();
    error InvalidNodeOperator();
    error NoFreeNodeOperator();
    error NodeAlreadyRegistered();
    error NodeNotRegistered();
    error NodeCurrentlyAssigned();
    error FactoryNotConfigured();
    error InsufficientFees();
    error FeeTooHigh();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event NodeOperatorCreated(address indexed node, address indexed nodeOperator);
    event NodeRemoved(address indexed node, address indexed nodeOperator);
    event UserBoundToNodeOperator(address indexed user, address indexed nodeOperator);
    event UserUnboundFromNodeOperator(address indexed user, address indexed nodeOperator);
    event FeesWithdrawn(uint256 amount, address indexed to);
    event MinStakeUpdated(uint256 oldMinStake, uint256 newMinStake);

    // ──────────────────────────────────────────────
    // Shared configuration
    // ──────────────────────────────────────────────

    address public stakingOperators;
    address public rewardPolicy;
    address public stakingToken;
    address public rewardToken;
    uint256 public defaultWithdrawFeeBps = 3000;
    uint256 public defaultRestakeFeeBps = 1500;
    uint256 public minStake;
    uint256 public constant MAX_FEE_BPS = 10000; // hard cap: 100%

    // ──────────────────────────────────────────────
    // Registry state
    // ──────────────────────────────────────────────

    // Bidirectional lookups
    mapping(address => address) public operatorToNode; // operator contract → node
    mapping(address => address) public userToOperator; // user → operator contract
    mapping(address => address) public userToNode; // user → node
    mapping(address => address) public nodeToUser; // node → user

    // Node list with O(1) removal (swap-and-pop)
    address[] private _allNodes;
    mapping(address => uint256) private _nodeIndexPlusOne; // 1-indexed; 0 = not in list

    // Parallel operator list (same indices as _allNodes)
    address[] private _allOperators;

    // Free node list with O(1) add/remove/pop (swap-and-pop)
    address[] private _freeNodes;
    mapping(address => uint256) private _freeNodeIndexPlusOne; // 1-indexed; 0 = not free

    constructor(address owner_) Ownable(owner_) {}

    // ──────────────────────────────────────────────
    // Config setters (onlyOwner)
    // ──────────────────────────────────────────────

    function setStakingOperators(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        stakingOperators = addr;
    }

    function setRewardPolicy(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        rewardPolicy = addr;
    }

    function setStakingToken(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        stakingToken = addr;
    }

    function setRewardToken(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        rewardToken = addr;
    }

    function setDefaultModeFeeBps(uint256 withdrawBps, uint256 restakeBps) external onlyOwner {
        if (withdrawBps > MAX_FEE_BPS || restakeBps > MAX_FEE_BPS) revert FeeTooHigh();
        defaultWithdrawFeeBps = withdrawBps;
        defaultRestakeFeeBps = restakeBps;
    }

    function setOperatorModeFeeBps(address operatorAddr, uint256 withdrawBps, uint256 restakeBps) external onlyOwner {
        if (operatorAddr == address(0)) revert ZeroAddress();
        if (operatorToNode[operatorAddr] == address(0)) revert InvalidNodeOperator();
        INodeOperator(operatorAddr).setModeFeeBps(withdrawBps, restakeBps);
    }

    function setMinStake(uint256 newMinStake) external onlyOwner {
        emit MinStakeUpdated(minStake, newMinStake);
        minStake = newMinStake;
    }

    /// @notice Pushes the factory's current token/operator addresses to a single NodeOperator.
    ///         Use after updating factory config to keep an existing operator in sync.
    function syncOperatorConfig(address operatorAddr) external onlyOwner {
        if (operatorAddr == address(0)) revert ZeroAddress();
        if (operatorToNode[operatorAddr] == address(0)) revert InvalidNodeOperator();
        _syncOperatorConfig(operatorAddr);
    }

    /// @notice Pushes the factory's current config to every registered NodeOperator.
    function syncAllOperatorConfigs() external onlyOwner {
        uint256 len = _allOperators.length;
        for (uint256 i; i < len;) {
            _syncOperatorConfig(_allOperators[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _syncOperatorConfig(address operatorAddr) internal {
        NodeOperator op = NodeOperator(operatorAddr);
        if (stakingOperators != address(0)) op.setStakingOperators(stakingOperators);
        if (rewardPolicy != address(0)) op.setRewardPolicy(rewardPolicy);
        if (stakingToken != address(0)) op.setStakingToken(stakingToken);
        if (rewardToken != address(0)) op.setRewardToken(rewardToken);
        op.setMinStake(minStake);
    }

    function withdrawFees(uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (rewardToken == address(0)) revert FactoryNotConfigured();
        uint256 fees = IERC20(rewardToken).balanceOf(address(this));
        if (amount > fees) revert InsufficientFees();
        IERC20(rewardToken).safeTransfer(to, amount);
        emit FeesWithdrawn(amount, to);
    }

    // ──────────────────────────────────────────────
    // Node management (onlyOwner)
    // ──────────────────────────────────────────────

    function _addNode(address node) internal returns (address operatorAddr) {
        if (node == address(0)) revert ZeroAddress();
        if (_nodeIndexPlusOne[node] != 0) revert NodeAlreadyRegistered();
        if (
            stakingOperators == address(0) || stakingToken == address(0) || rewardPolicy == address(0)
                || rewardToken == address(0)
        ) revert FactoryNotConfigured();

        NodeOperator operator =
            new NodeOperator(address(this), minStake, node, stakingOperators, rewardPolicy, stakingToken, rewardToken);
        operator.setModeFeeBps(defaultWithdrawFeeBps, defaultRestakeFeeBps);

        operatorAddr = address(operator);

        _allNodes.push(node);
        _allOperators.push(operatorAddr);
        _nodeIndexPlusOne[node] = _allNodes.length;
        operatorToNode[operatorAddr] = node;
        _freeNodes.push(node);
        _freeNodeIndexPlusOne[node] = _freeNodes.length;

        emit NodeOperatorCreated(node, operatorAddr);
    }

    function addNode(address node) external onlyOwner returns (address) {
        return _addNode(node);
    }

    function addNodes(address[] calldata nodes) external onlyOwner {
        uint256 len = nodes.length;
        for (uint256 i; i < len;) {
            _addNode(nodes[i]);
            unchecked {
                ++i;
            }
        }
    }

    function removeNode(address node) external onlyOwner {
        uint256 idxPlusOne = _nodeIndexPlusOne[node];
        if (idxPlusOne == 0) revert NodeNotRegistered();
        if (_freeNodeIndexPlusOne[node] == 0) revert NodeCurrentlyAssigned();

        uint256 idx = idxPlusOne - 1;
        address operatorAddr = _allOperators[idx];

        // O(1) remove from _allNodes / _allOperators (parallel swap-and-pop)
        uint256 last = _allNodes.length - 1;
        if (idx != last) {
            address swappedNode = _allNodes[last];
            address swappedOp = _allOperators[last];
            _allNodes[idx] = swappedNode;
            _allOperators[idx] = swappedOp;
            _nodeIndexPlusOne[swappedNode] = idx + 1;
        }
        _allNodes.pop();
        _allOperators.pop();
        _nodeIndexPlusOne[node] = 0;

        // O(1) remove from _freeNodes
        _removeFromFreeList(node);

        delete operatorToNode[operatorAddr];

        emit NodeRemoved(node, operatorAddr);
    }

    // ──────────────────────────────────────────────
    // User operations (auto-binding + token relay)
    // ──────────────────────────────────────────────

    function stake(uint256 amount) external nonReentrant {
        address operatorAddr = userToOperator[msg.sender];
        if (operatorAddr == address(0)) {
            operatorAddr = _bindFreeNode(msg.sender);
            emit UserBoundToNodeOperator(msg.sender, operatorAddr);
        }
        INodeOperator(operatorAddr).assignUser(msg.sender);
        // Relay tokens: user → NodeOperator (skip Factory hop)
        IERC20(stakingToken).safeTransferFrom(msg.sender, operatorAddr, amount);
        INodeOperator(operatorAddr).stake();
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        address operatorAddr = userToOperator[msg.sender];
        if (operatorAddr == address(0)) revert NoBoundNodeOperator();
        INodeOperator(operatorAddr).requestUnstake(amount);
    }

    function withdrawUnstaked() external nonReentrant {
        address operatorAddr = userToOperator[msg.sender];
        if (operatorAddr == address(0)) revert NoBoundNodeOperator();
        INodeOperator(operatorAddr).withdrawUnstaked();

        if (INodeOperator(operatorAddr).nodeUser() == address(0)) {
            _cleanupUserBinding(msg.sender, operatorAddr);
        }
    }

    function claimRewards() external nonReentrant {
        address operatorAddr = userToOperator[msg.sender];
        if (operatorAddr == address(0)) revert NoBoundNodeOperator();
        INodeOperator(operatorAddr).harvestRewards();
    }

    function setMyRewardBehavior(uint8 behavior) external nonReentrant {
        address operatorAddr = userToOperator[msg.sender];
        if (operatorAddr == address(0)) revert NoBoundNodeOperator();
        INodeOperator(operatorAddr).setRewardBehavior(behavior);
    }

    function pendingRewards(address user) external view returns (uint256) {
        address operatorAddr = userToOperator[user];
        if (operatorAddr == address(0)) return 0;
        if (rewardPolicy == address(0)) return 0;
        if (INodeOperator(operatorAddr).nodeUser() != user) return 0;
        return IRewardPolicyExtended(rewardPolicy).rewards(operatorAddr);
    }

    /// @notice Intentionally permissionless so keepers/bots can trigger harvesting.
    function harvestRewards(address operatorAddr) external nonReentrant {
        if (operatorAddr == address(0)) revert ZeroAddress();
        if (operatorToNode[operatorAddr] == address(0)) revert InvalidNodeOperator();
        INodeOperator(operatorAddr).harvestRewards();
    }

    /// @notice Intentionally permissionless so keepers/bots can trigger batch harvesting.
    ///         Harvests all assigned nodes in a single transaction. For large registries,
    ///         prefer the paginated overload to avoid block gas limit issues-
    function harvestAllRewards() external {
        harvestAllRewards(0, _allNodes.length);
    }

    /// @notice Paginated variant of harvestAllRewards. Process `limit` nodes starting
    ///         at `offset` to stay within block gas limits with large node counts.
    /// @dev Individual harvest failures are swallowed so a single broken operator
    ///      cannot revert the entire batch.
    function harvestAllRewards(uint256 offset, uint256 limit) public nonReentrant {
        uint256 total = _allNodes.length;
        uint256 end = offset + limit;
        if (end > total) end = total;
        for (uint256 i = offset; i < end;) {
            if (_freeNodeIndexPlusOne[_allNodes[i]] == 0) {
                // solhint-disable-next-line no-empty-blocks
                try INodeOperator(_allOperators[i]).harvestRewards() {} catch {}
            }
            unchecked {
                ++i;
            }
        }
    }

    // ──────────────────────────────────────────────
    // Admin: force-release abandoned users after unstake matures
    // ──────────────────────────────────────────────

    /// @notice Admin withdraws matured tranches and frees the node if fully drained.
    /// This is to prevent nodes with no stake from being stuck in the system.
    /// This function is only meant to be used in emergency situations.
    function forceWithdrawAndRelease(address operatorAddr) external onlyOwner {
        if (operatorToNode[operatorAddr] == address(0)) revert InvalidNodeOperator();
        address user = INodeOperator(operatorAddr).nodeUser();
        if (user == address(0)) revert NoBoundNodeOperator();
        // Harvest any pending rewards first
        // solhint-disable-next-line no-empty-blocks
        INodeOperator(operatorAddr).setRewardBehavior(uint8(NodeOperator.RewardBehavior.WithdrawToUser));
        try INodeOperator(operatorAddr).harvestRewards() {} catch {}
        INodeOperator(operatorAddr).withdrawUnstaked();
        if (INodeOperator(operatorAddr).nodeUser() == address(0)) {
            _cleanupUserBinding(user, operatorAddr);
        }
    }

    // ──────────────────────────────────────────────
    // View functions
    // ──────────────────────────────────────────────

    function allNodes() external view returns (address[] memory) {
        return _allNodes;
    }

    function nodeCount() external view returns (uint256) {
        return _allNodes.length;
    }

    function allNodeOperators() external view returns (address[] memory) {
        return _allOperators;
    }

    function isFreeNode(address node) external view returns (bool) {
        return _freeNodeIndexPlusOne[node] != 0;
    }

    function myRewardBehavior(address user) external view returns (uint8) {
        address operatorAddr = userToOperator[user];
        if (operatorAddr == address(0)) revert NoBoundNodeOperator();
        return INodeOperator(operatorAddr).rewardBehavior();
    }

    function operatorModeFeeBps(address operatorAddr) external view returns (uint256 withdrawBps, uint256 restakeBps) {
        if (operatorAddr == address(0)) revert ZeroAddress();
        if (operatorToNode[operatorAddr] == address(0)) revert InvalidNodeOperator();
        withdrawBps = INodeOperator(operatorAddr).withdrawFeeBps();
        restakeBps = INodeOperator(operatorAddr).restakeFeeBps();
    }

    function freeNodeCount() external view returns (uint256) {
        return _freeNodes.length;
    }

    function nodeToOperator(address node) external view returns (address) {
        uint256 idxPlusOne = _nodeIndexPlusOne[node];
        if (idxPlusOne == 0) return address(0);
        return _allOperators[idxPlusOne - 1];
    }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    function _cleanupUserBinding(address user, address operatorAddr) internal {
        INodeOperator(operatorAddr).resetRewardBehavior();
        address node = userToNode[user];
        _freeNodes.push(node);
        _freeNodeIndexPlusOne[node] = _freeNodes.length;
        delete nodeToUser[node];
        delete userToNode[user];
        delete userToOperator[user];
        emit UserUnboundFromNodeOperator(user, operatorAddr);
    }

    function _bindFreeNode(address user) internal returns (address operatorAddr) {
        if (_freeNodes.length == 0) revert NoFreeNodeOperator();

        // O(1): pop last free node
        address node = _freeNodes[_freeNodes.length - 1];
        _freeNodes.pop();
        _freeNodeIndexPlusOne[node] = 0;

        // Look up operator via the node index
        operatorAddr = _allOperators[_nodeIndexPlusOne[node] - 1];

        userToOperator[user] = operatorAddr;
        userToNode[user] = node;
        nodeToUser[node] = user;
    }

    function _removeFromFreeList(address node) internal {
        uint256 idxPlusOne = _freeNodeIndexPlusOne[node];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;
        uint256 last = _freeNodes.length - 1;
        if (idx != last) {
            address swapped = _freeNodes[last];
            _freeNodes[idx] = swapped;
            _freeNodeIndexPlusOne[swapped] = idx + 1;
        }
        _freeNodes.pop();
        _freeNodeIndexPlusOne[node] = 0;
    }
}
