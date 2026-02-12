// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../../src/NodeOperator.sol";

/// @title DeployNodeOperator
/// @notice Deploys the NodeOperator contract and configures it.
/// @dev Environment variables:
///      - PRIVATE_KEY: Deployer private key (required)
///      - STAKING_OPERATORS: StakingOperators contract address (required)
///      - REWARD_POLICY: RewardPolicy contract address (required)
///      - STAKE_TOKEN: Staking token address (required)
///      - REWARD_TOKEN: Reward token address (required)
///      - NODE_ADDRESS: Node/operator address managed by this instance (required)
///      - ROUTER_FACTORY: Factory/router address allowed to call user operations (required)
///      - WITHDRAW_FEE_BPS: Withdraw-mode fee in basis points (default: 3000 = 30%)
///      - RESTAKE_FEE_BPS: Restake-mode fee in basis points (default: 1500 = 15%)
///      - MIN_STAKE: Minimum first-stake amount (default: 1_000_000e6 = 1M NIL)
contract DeployNodeOperator is Script {
    function run() external returns (NodeOperator nodeOperator) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address stakingOperators = vm.envAddress("STAKING_OPERATORS");
        address rewardPolicyAddr = vm.envAddress("REWARD_POLICY");
        address stakeToken = vm.envAddress("STAKE_TOKEN");
        address rewardTokenAddr = vm.envAddress("REWARD_TOKEN");
        address nodeAddress = vm.envAddress("NODE_ADDRESS");
        address routerFactory = vm.envAddress("ROUTER_FACTORY");
        uint256 withdrawFeeBpsVal = vm.envOr("WITHDRAW_FEE_BPS", uint256(3000));
        uint256 restakeFeeBpsVal = vm.envOr("RESTAKE_FEE_BPS", uint256(1500));
        uint256 minStakeVal = vm.envOr("MIN_STAKE", uint256(1_000_000e6));

        vm.startBroadcast(deployerPrivateKey);

        nodeOperator = new NodeOperator(
            deployer,
            minStakeVal,
            routerFactory,
            nodeAddress,
            stakingOperators,
            rewardPolicyAddr,
            stakeToken,
            rewardTokenAddr
        );
        nodeOperator.setModeFeeBps(withdrawFeeBpsVal, restakeFeeBpsVal);

        vm.stopBroadcast();

        console.log("NodeOperator deployed at:", address(nodeOperator));
        console.log("Withdraw Fee BPS:", withdrawFeeBpsVal);
        console.log("Restake Fee BPS:", restakeFeeBpsVal);
    }
}
