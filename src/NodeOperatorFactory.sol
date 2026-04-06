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
    error FactoryNotConfigured();
    error InsufficientFees();
    error FeeTooHigh();
    error TokenMismatch();
    error StakerNotPreapproved();
    error StakingOperatorsQueryFailed();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event NodeOperatorCreated(address indexed node, address indexed nodeOperator);

    event UserBoundToNodeOperator(address indexed user, address indexed nodeOperator);

    event FeesWithdrawn(uint256 amount, address indexed to);
    event MinStakeUpdated(uint256 oldMinStake, uint256 newMinStake);
    event HarvestFailed(address indexed operatorAddr, bytes reason);
    event DependenciesUpdated(
        address oldStaking, address newStaking, address oldReward, address newReward, address oldToken, address newToken
    );
    event DefaultModeFeeBpsUpdated(
        uint256 oldWithdrawBps, uint256 newWithdrawBps, uint256 oldRestakeBps, uint256 newRestakeBps
    );
    event OperatorConfigSynced(address indexed operatorAddr);

    // ──────────────────────────────────────────────
    // Shared configuration
    // ──────────────────────────────────────────────

    address public stakingOperators;
    address public rewardPolicy;
    address public token;
    uint256 public defaultWithdrawFeeBps = 3000;
    uint256 public defaultRestakeFeeBps = 1500;
    uint256 public minStake;
    uint256 public constant MAX_FEE_BPS = 5000; // hard cap: 50%

    // ──────────────────────────────────────────────
    // Registry state
    // ──────────────────────────────────────────────

    // Bidirectional lookups
    mapping(address => address) public operatorToNode; // operator contract → node
    mapping(address => address) public userToOperator; // user → operator contract
    mapping(address => address) public userToNode; // user → node
    mapping(address => address) public nodeToUser; // node → user

    // Node list (append-only)
    address[] private _allNodes;
    mapping(address => uint256) private _nodeIndexPlusOne; // 1-indexed; 0 = not in list

    // Parallel operator list (same indices as _allNodes)
    address[] private _allOperators;

    // Free node list with O(1) add/pop
    address[] private _freeNodes;
    mapping(address => uint256) private _freeNodeIndexPlusOne; // 1-indexed; 0 = not free

    function renounceOwnership() public pure override {
        revert("disabled");
    }

    constructor(address owner_, address stakingOperators_, address rewardPolicy_, address token_, uint256 minStake_)
        Ownable(owner_)
    {
        if (stakingOperators_ == address(0)) revert ZeroAddress();
        if (rewardPolicy_ == address(0)) revert ZeroAddress();
        if (token_ == address(0)) revert ZeroAddress();
        if (IStakingOperators(stakingOperators_).stakingToken() != token_) revert TokenMismatch();
        if (IRewardPolicyExtended(rewardPolicy_).rewardToken() != token_) revert TokenMismatch();
        stakingOperators = stakingOperators_;
        rewardPolicy = rewardPolicy_;
        token = token_;
        minStake = minStake_;
    }

    // ──────────────────────────────────────────────
    // Config setters (onlyOwner)
    // ──────────────────────────────────────────────

    /// @notice Atomically updates the dependency tuple, enforcing token compatibility.
    function setDependencies(address stakingOperators_, address rewardPolicy_, address token_) external onlyOwner {
        if (stakingOperators_ == address(0) || rewardPolicy_ == address(0) || token_ == address(0)) {
            revert ZeroAddress();
        }
        if (IStakingOperators(stakingOperators_).stakingToken() != token_) revert TokenMismatch();
        if (IRewardPolicyExtended(rewardPolicy_).rewardToken() != token_) revert TokenMismatch();
        emit DependenciesUpdated(stakingOperators, stakingOperators_, rewardPolicy, rewardPolicy_, token, token_);
        stakingOperators = stakingOperators_;
        rewardPolicy = rewardPolicy_;
        token = token_;
    }

    function setDefaultModeFeeBps(uint256 withdrawBps, uint256 restakeBps) external onlyOwner {
        if (withdrawBps > MAX_FEE_BPS || restakeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit DefaultModeFeeBpsUpdated(defaultWithdrawFeeBps, withdrawBps, defaultRestakeFeeBps, restakeBps);
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

    /// @notice Transfers ownership of a NodeOperator to a new address (e.g. a replacement factory).
    function migrateOperator(address operatorAddr, address newOwner) external onlyOwner {
        if (operatorAddr == address(0)) revert ZeroAddress();
        if (newOwner == address(0)) revert ZeroAddress();
        if (operatorToNode[operatorAddr] == address(0)) revert InvalidNodeOperator();
        NodeOperator(operatorAddr).transferOwnership(newOwner);
    }

    /// @notice Pushes the factory's current dependencies (stakingOperators, rewardPolicy,
    ///         token, minStake) to a single NodeOperator. Fee rates (withdrawFeeBps,
    ///         restakeFeeBps) are intentionally per-operator and excluded from sync;
    ///         use setOperatorModeFeeBps() to update fees on individual operators.
    function syncOperatorConfig(address operatorAddr) external onlyOwner {
        if (operatorAddr == address(0)) revert ZeroAddress();
        if (operatorToNode[operatorAddr] == address(0)) revert InvalidNodeOperator();
        _syncOperatorConfig(operatorAddr);
    }

    /// @notice Pushes the factory's current dependencies to every registered NodeOperator.
    /// @dev Fee rates are intentionally excluded; see syncOperatorConfig().
    function syncAllOperatorConfigs() external onlyOwner {
        uint256 len = _allOperators.length;
        for (uint256 i; i < len;) {
            _syncOperatorConfig(_allOperators[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Syncs dependencies only (stakingOperators, rewardPolicy, token, minStake).
    ///      Fee rates are per-operator and intentionally excluded from synchronization.
    function _syncOperatorConfig(address operatorAddr) internal {
        NodeOperator op = NodeOperator(operatorAddr);
        if (stakingOperators != address(0)) op.setStakingOperators(stakingOperators);
        if (rewardPolicy != address(0)) op.setRewardPolicy(rewardPolicy);
        if (token != address(0)) op.setToken(token);
        op.setMinStake(minStake);
        emit OperatorConfigSynced(operatorAddr);
    }

    /// @notice Rescues stranded ERC-20 tokens from a NodeOperator (e.g. after token migration).
    function rescueOperatorTokens(address operatorAddr, IERC20 rescueToken, address to, uint256 amount)
        external
        onlyOwner
    {
        if (operatorAddr == address(0)) revert ZeroAddress();
        if (operatorToNode[operatorAddr] == address(0)) revert InvalidNodeOperator();
        NodeOperator(operatorAddr).rescueTokens(rescueToken, to, amount);
    }

    /// @notice Withdraws token fees accumulated from NodeOperator harvest calls.
    function withdrawFees(uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) revert FactoryNotConfigured();
        uint256 fees = IERC20(token).balanceOf(address(this));
        if (amount > fees) revert InsufficientFees();
        IERC20(token).safeTransfer(to, amount);
        emit FeesWithdrawn(amount, to);
    }

    // ──────────────────────────────────────────────
    // Node management (onlyOwner)
    // ──────────────────────────────────────────────

    function _addNode(address node) internal returns (address operatorAddr) {
        if (node == address(0)) revert ZeroAddress();
        if (_nodeIndexPlusOne[node] != 0) revert NodeAlreadyRegistered();
        if (stakingOperators == address(0) || token == address(0) || rewardPolicy == address(0)) {
            revert FactoryNotConfigured();
        }
        operatorAddr = predictNodeOperatorAddress(node);
        if (_approvedStaker(node) != operatorAddr) revert StakerNotPreapproved();

        NodeOperator operator = new NodeOperator{salt: _nodeOperatorSalt(node)}(
            address(this),
            minStake,
            node,
            stakingOperators,
            rewardPolicy,
            token,
            defaultWithdrawFeeBps,
            defaultRestakeFeeBps
        );

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
        IERC20(token).safeTransferFrom(msg.sender, operatorAddr, amount);
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
    }

    function claimRewards() external nonReentrant {
        address operatorAddr = userToOperator[msg.sender];
        if (operatorAddr == address(0)) revert NoBoundNodeOperator();
        INodeOperator(operatorAddr).harvestRewards();
    }

    function setMyRewardBehavior(INodeOperator.RewardBehavior behavior) external nonReentrant {
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
    ///         prefer the paginated overload to avoid block gas limit issues.
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
            try INodeOperator(_allOperators[i]).harvestRewards() {}
            catch (bytes memory reason) {
                emit HarvestFailed(_allOperators[i], reason);
            }
            unchecked {
                ++i;
            }
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

    function predictNodeOperatorAddress(address node) public view returns (address) {
        bytes32 salt = _nodeOperatorSalt(node);
        bytes32 initCodeHash = keccak256(_nodeOperatorInitCode(node));
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    function _nodeOperatorSalt(address node) internal pure returns (bytes32) {
        return keccak256(abi.encode(node));
    }

    function _nodeOperatorInitCode(address node) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(NodeOperator).creationCode,
            abi.encode(
                address(this),
                minStake,
                node,
                stakingOperators,
                rewardPolicy,
                token,
                defaultWithdrawFeeBps,
                defaultRestakeFeeBps
            )
        );
    }

    function _approvedStaker(address node) internal view returns (address approved) {
        (bool ok, bytes memory data) =
            stakingOperators.staticcall(abi.encodeWithSignature("approvedStaker(address)", node));
        if (!ok || data.length < 32) revert StakingOperatorsQueryFailed();
        approved = abi.decode(data, (address));
    }

    /// @dev Pops the last free node (LIFO) and maps it to `user`.
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
}
