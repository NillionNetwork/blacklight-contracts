// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../../src/StakingOperators.sol";
import "../../src/NodeOperatorFactory.sol";

/// @title DebugApprovedStakers
/// @notice Prints approved/current stakers and stake amounts for node operators.
/// @dev Env vars:
///      - STAKING_OPERATORS (required): StakingOperators contract address
///      - NODE_OPERATOR_FACTORY (optional): if set, iterates over factory allNodes()
contract DebugApprovedStakers is Script {
    function run() external view {
        address stakingAddr = vm.envAddress("STAKING_OPERATORS");
        address factoryAddr = vm.envOr("NODE_OPERATOR_FACTORY", address(0));

        require(stakingAddr != address(0), "STAKING_OPERATORS is required");

        StakingOperators staking = StakingOperators(stakingAddr);

        console2.log("=== StakingOperators Debug ===");
        console2.log("stakingOperators:", stakingAddr);
        console2.log("stakingToken:", staking.stakingToken());
        console2.log("totalStaked:", staking.totalStaked());
        console2.log("activeOperators:", staking.getActiveOperators().length);

        if (factoryAddr != address(0)) {
            _reportFromFactory(staking, factoryAddr);
            return;
        }

        _reportFromActiveOperators(staking);
    }

    function _reportFromFactory(StakingOperators staking, address factoryAddr) internal view {
        NodeOperatorFactory factory = NodeOperatorFactory(factoryAddr);
        address[] memory nodes = factory.allNodes();

        console2.log("factory:", factoryAddr);
        console2.log("nodeCount:", nodes.length);

        for (uint256 i = 0; i < nodes.length; ++i) {
            address node = nodes[i];
            _printOperatorStakeState(staking, node, i);
        }
    }

    function _reportFromActiveOperators(StakingOperators staking) internal view {
        address[] memory active = staking.getActiveOperators();

        console2.log("factory: <not provided>");
        console2.log("showing active operators only");

        for (uint256 i = 0; i < active.length; ++i) {
            _printOperatorStakeState(staking, active[i], i);
        }
    }

    function _printOperatorStakeState(StakingOperators staking, address operator, uint256 index) internal view {
        IStakingOperators.OperatorInfo memory info = staking.getOperatorInfo(operator);

        console2.log("--------------------------------");
        console2.log("index:", index);
        console2.log("operator(node):", operator);
        console2.log("approvedStaker:", staking.approvedStaker(operator));
        console2.log("currentStaker:", staking.operatorStaker(operator));
        console2.log("stake:", staking.stakeOf(operator));
        console2.log("isActive:", staking.isActiveOperator(operator));
        console2.log("isJailed:", staking.isJailed(operator));
        console2.log("registeredActiveFlag:", info.active);
        console2.log("metadataURI:", info.metadataURI);
    }
}
