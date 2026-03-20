// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Vm.sol";

import "../../../src/mocks/TESTToken.sol";
import "../../../src/StakingOperators.sol";
import "../../../src/RewardPolicy.sol";
import "../../../src/NodeOperatorFactory.sol";

library BlacklightNodeOpsLib {
    function deployNodeFactoryAndManagedNodes(
        Vm vm,
        bool deployNodeFactory,
        address deployer,
        StakingOperators stakingOps,
        RewardPolicy rewardPolicy,
        TESTToken token
    ) internal returns (NodeOperatorFactory nodeFactory, address[] memory managedNodes, uint256[] memory managedNodeKeys) {
        managedNodes = new address[](0);
        managedNodeKeys = new uint256[](0);
        if (!deployNodeFactory) return (nodeFactory, managedNodes, managedNodeKeys);

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 numOperators = vm.envUint("NUM_OPERATORS");
        uint256 numManagedNodes = vm.envOr("NUM_MANAGED_NODES", uint256(10));
        uint256 managedNodesOffset = vm.envOr("MANAGED_NODES_OFFSET", numOperators);
        uint256 factoryWithdrawFeeBps = vm.envOr("FACTORY_WITHDRAW_FEE_BPS", uint256(3000));
        uint256 factoryRestakeFeeBps = vm.envOr("FACTORY_RESTAKE_FEE_BPS", uint256(1500));
        uint256 factoryMinStake = vm.envOr("FACTORY_MIN_STAKE", uint256(1_000_000e6));

        nodeFactory = new NodeOperatorFactory(
            deployer, address(stakingOps), address(rewardPolicy), address(token), factoryMinStake
        );
        nodeFactory.setDefaultModeFeeBps(factoryWithdrawFeeBps, factoryRestakeFeeBps);

        managedNodes = new address[](numManagedNodes);
        managedNodeKeys = new uint256[](numManagedNodes);
        for (uint256 i = 0; i < numManagedNodes; i++) {
            uint256 key = vm.deriveKey(mnemonic, uint32(managedNodesOffset + i));
            managedNodeKeys[i] = key;
            managedNodes[i] = vm.addr(key);
        }

        for (uint256 i = 0; i < numManagedNodes; i++) {
            (bool ok,) = managedNodes[i].call{value: 0.01 ether}("");
            require(ok, "ETH transfer failed");
        }
    }

    function fundExtraNodes(Vm vm, bool deployNodeFactory, TESTToken token) internal {
        uint256 fundedNodes = vm.envOr("FUNDED_NODES", uint256(0));
        if (fundedNodes == 0) return;

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 fundedTokenAmount = vm.envUint("FUNDED_TOKEN_AMOUNT");
        uint256 fundedEthAmount = vm.envUint("FUNDED_ETH_AMOUNT");

        uint256 fundedBaseIndex = vm.envUint("NUM_OPERATORS");
        if (deployNodeFactory) {
            fundedBaseIndex += vm.envOr("NUM_MANAGED_NODES", uint256(10));
        }

        for (uint256 i = 0; i < fundedNodes; i++) {
            address addr = vm.addr(vm.deriveKey(mnemonic, uint32(fundedBaseIndex + i)));
            token.mint(addr, fundedTokenAmount);
            (bool ok,) = addr.call{value: fundedEthAmount}("");
            require(ok, "ETH transfer failed");
        }
    }

    function approveManagedNodeStakers(
        Vm vm,
        address[] memory managedNodes,
        uint256[] memory managedNodeKeys,
        NodeOperatorFactory nodeFactory,
        StakingOperators stakingOps
    ) internal {
        for (uint256 i = 0; i < managedNodes.length; i++) {
            address predictedOp = nodeFactory.predictNodeOperatorAddress(managedNodes[i]);
            vm.broadcast(managedNodeKeys[i]);
            stakingOps.approveStaker(predictedOp);
        }
    }

    function addManagedNodes(NodeOperatorFactory nodeFactory, address[] memory managedNodes) internal {
        nodeFactory.addNodes(managedNodes);
    }
}
