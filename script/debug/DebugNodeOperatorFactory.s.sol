// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../../src/NodeOperatorFactory.sol";
import "../../src/NodeOperator.sol";
import "../../src/StakingOperators.sol";

/// @title DebugNodeOperatorFactory
/// @notice Prints NodeOperatorFactory config/state and per-NodeOperator details.
/// @dev Env vars:
///      - NODE_OPERATOR_FACTORY (required): NodeOperatorFactory address
contract DebugNodeOperatorFactory is Script {
    function run() external view {
        address factoryAddr = vm.envAddress("NODE_OPERATOR_FACTORY");
        require(factoryAddr != address(0), "NODE_OPERATOR_FACTORY is required");

        NodeOperatorFactory factory = NodeOperatorFactory(factoryAddr);

        address stakingAddr = factory.stakingOperators();
        StakingOperators staking = StakingOperators(stakingAddr);

        address[] memory nodes = factory.allNodes();
        address[] memory operators = factory.allNodeOperators();

        console2.log("=== NodeOperatorFactory Debug ===");
        console2.log("factory:", factoryAddr);
        console2.log("owner:", factory.owner());
        console2.log("stakingOperators:", stakingAddr);
        console2.log("rewardPolicy:", factory.rewardPolicy());
        console2.log("stakingToken:", factory.stakingToken());
        console2.log("rewardToken:", factory.rewardToken());
        console2.log("defaultWithdrawFeeBps:", factory.defaultWithdrawFeeBps());
        console2.log("defaultRestakeFeeBps:", factory.defaultRestakeFeeBps());
        console2.log("minStake:", factory.minStake());
        console2.log("nodeCount:", factory.nodeCount());
        console2.log("freeNodeCount:", factory.freeNodeCount());
        console2.log("allNodes.length:", nodes.length);
        console2.log("allNodeOperators.length:", operators.length);

        require(nodes.length == operators.length, "nodes/operators length mismatch");

        for (uint256 i = 0; i < nodes.length; ++i) {
            _printNodeState(factory, staking, nodes[i], operators[i], i);
        }
    }

    function _printNodeState(
        NodeOperatorFactory factory,
        StakingOperators staking,
        address node,
        address operatorAddr,
        uint256 index
    ) internal view {
        NodeOperator nodeOperator = NodeOperator(operatorAddr);

        address mappedNode = factory.operatorToNode(operatorAddr);
        address mappedOperator = factory.nodeToOperator(node);
        address assignedUser = factory.nodeToUser(node);
        bool isFree = factory.isFreeNode(node);

        console2.log("--------------------------------");
        console2.log("index:", index);
        console2.log("node:", node);
        console2.log("nodeOperator:", operatorAddr);
        console2.log("factory.operatorToNode:", mappedNode);
        console2.log("factory.nodeToOperator:", mappedOperator);
        console2.log("factory.nodeToUser:", assignedUser);
        console2.log("factory.isFreeNode:", isFree);

        console2.log("nodeOperator.owner:", nodeOperator.owner());
        console2.log("nodeOperator.nodeAddress:", nodeOperator.nodeAddress());
        console2.log("nodeOperator.nodeUser:", nodeOperator.nodeUser());
        console2.log("nodeOperator.withdrawFeeBps:", nodeOperator.withdrawFeeBps());
        console2.log("nodeOperator.restakeFeeBps:", nodeOperator.restakeFeeBps());
        console2.log("nodeOperator.minStake:", nodeOperator.minStake());
        console2.log("nodeOperator.stakingOperators:", address(nodeOperator.stakingOperators()));
        console2.log("nodeOperator.rewardPolicy:", address(nodeOperator.rewardPolicy()));

        console2.log("staking.stakeOf(node):", staking.stakeOf(node));
        console2.log("staking.operatorStaker(node):", staking.operatorStaker(node));
        console2.log("staking.approvedStaker(node):", staking.approvedStaker(node));
        console2.log("staking.isActive(node):", staking.isActiveOperator(node));
        console2.log("staking.isJailed(node):", staking.isJailed(node));
    }
}
