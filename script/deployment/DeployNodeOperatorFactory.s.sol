// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../../src/NodeOperatorFactory.sol";

/// @title DeployNodeOperatorFactory
/// @notice Deploys and configures a NodeOperatorFactory against real (non-mock) tokens.
/// @dev Required env vars:
///      - PRIVATE_KEY
///      - STAKING_OPERATORS
///      - REWARD_POLICY
///      - STAKE_TOKEN
///
///      Optional env vars:
///      - FACTORY_WITHDRAW_FEE_BPS (default: 3000)
///      - FACTORY_RESTAKE_FEE_BPS  (default: 1500)
///      - FACTORY_MIN_STAKE        (default: 1_000_000e6, i.e. 1 million NIL with 6 decimals)
contract DeployNodeOperatorFactory is Script {
    function run() external returns (NodeOperatorFactory factory) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address stakingOps   = vm.envAddress("STAKING_OPERATORS");
        address rewardPolicy = vm.envAddress("REWARD_POLICY");
        address stakeToken   = vm.envAddress("STAKE_TOKEN");
        uint256 withdrawFeeBps = vm.envOr("FACTORY_WITHDRAW_FEE_BPS", uint256(3000));
        uint256 restakeFeeBps  = vm.envOr("FACTORY_RESTAKE_FEE_BPS",  uint256(1500));
        uint256 minStake       = vm.envOr("FACTORY_MIN_STAKE",        uint256(1_000_000e6));

        vm.startBroadcast(deployerPrivateKey);

        factory = new NodeOperatorFactory(deployer, stakingOps, rewardPolicy, stakeToken, minStake);
        factory.setDefaultModeFeeBps(withdrawFeeBps, restakeFeeBps);

        vm.stopBroadcast();

        console.log("NodeOperatorFactory:", address(factory));
        console.log("  owner:            ", deployer);
        console.log("  stakingOperators: ", stakingOps);
        console.log("  rewardPolicy:     ", rewardPolicy);
        console.log("  token:            ", stakeToken);
        console.log("  withdrawFeeBps:   ", withdrawFeeBps);
        console.log("  restakeFeeBps:    ", restakeFeeBps);
        console.log("  minStake:         ", minStake);
    }
}
