// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../src/mocks/TESTToken.sol";
import "../src/StakingOperators.sol";
import "../src/WeightedCommitteeSelector.sol";
import "../src/ProtocolConfig.sol";
import "../src/HeartbeatManager.sol";
import "../src/RewardPolicy.sol";
import "../src/JailingPolicy.sol";
import "../src/NoOpSlashingPolicy.sol";
import {EmissionsController, IERC20Mintable, IL1StandardBridge} from "../src/EmissionsController.sol";
import "../src/mocks/MockL1StandardBridge.sol";

/// @title DeployBlacklight
/// @notice Deploys the complete Blacklight verifier network system
/// @dev Configurable via environment variables:
///      - PRIVATE_KEY: Deployer private key (required)
///      - UNSTAKE_DELAY: Time lock for unstaking (default: 7 days)
///      - BASE_COMMITTEE_SIZE: Initial committee size (default: 5)
///      - MAX_COMMITTEE_SIZE: Maximum committee size (default: 20)
///      - MAX_ESCALATIONS: Maximum escalation rounds (default: 3)
///      - QUORUM_BPS: Quorum threshold in basis points (default: 5000 = 50%)
///      - VERIFICATION_BPS: Verification threshold in basis points (default: 6667 = 66.67%)
///      - RESPONSE_WINDOW: Response window in seconds (default: 1 hour)
///      - JAIL_DURATION: Jail duration in seconds (default: 1 day)
///      - MIN_OPERATOR_STAKE: Minimum stake for operator activation (default: 1000e18)
///      - USE_NOOP_SLASHING: Set to "true" to use NoOpSlashingPolicy instead of JailingPolicy (default: false)
///      - DEPLOY_EMISSIONS: Set to "true" to deploy EmissionsController (default: false)
contract DeployBlacklight is Script {
    struct DeployedContracts {
        TESTToken token;
        StakingOperators stakingOps;
        WeightedCommitteeSelector selector;
        ProtocolConfig config;
        HeartbeatManager manager;
        RewardPolicy rewardPolicy;
        address slashingPolicy;
        EmissionsController emissionsController;
        MockL1StandardBridge mockBridge;
    }

    function run() external returns (DeployedContracts memory deployed) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Read configuration from environment or use defaults
        uint256 unstakeDelay = vm.envOr("UNSTAKE_DELAY", uint256(7 days));
        uint32 baseCommitteeSize = uint32(vm.envOr("BASE_COMMITTEE_SIZE", uint256(5)));
        uint32 maxCommitteeSize = uint32(vm.envOr("MAX_COMMITTEE_SIZE", uint256(20)));
        uint8 maxEscalations = uint8(vm.envOr("MAX_ESCALATIONS", uint256(3)));
        uint16 quorumBps = uint16(vm.envOr("QUORUM_BPS", uint256(5000))); // 50%
        uint16 verificationBps = uint16(vm.envOr("VERIFICATION_BPS", uint256(6667))); // 66.67%
        uint256 responseWindow = vm.envOr("RESPONSE_WINDOW", uint256(1 hours));
        uint256 jailDuration = vm.envOr("JAIL_DURATION", uint256(1 days));
        uint256 minOperatorStake = vm.envOr("MIN_OPERATOR_STAKE", uint256(10e6));
        bool useNoOpSlashing = vm.envOr("USE_NOOP_SLASHING", false);
        bool deployEmissions = vm.envOr("DEPLOY_EMISSIONS", false);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy tokens
        deployed.token = new TESTToken(deployer);

        // Deploy StakingOperators
        deployed.stakingOps = new StakingOperators(
            IERC20(address(deployed.token)),
            deployer,
            unstakeDelay
        );

        // Deploy WeightedCommitteeSelector
        deployed.selector = new WeightedCommitteeSelector(
            deployed.stakingOps,
            deployer,
            0, // minCommitteeVP (can be updated later)
            maxCommitteeSize
        );

        // Deploy ProtocolConfig with placeholder slashing/reward
        deployed.config = new ProtocolConfig(
            deployer, // owner
            address(deployed.stakingOps),
            address(deployed.selector),
            address(0x1111), // placeholder slashing
            address(0x2222), // placeholder reward
            baseCommitteeSize,
            0, // committeeSizeGrowthBps (no growth)
            maxCommitteeSize,
            maxEscalations,
            quorumBps,
            verificationBps,
            responseWindow,
            jailDuration,
            100, // maxVoteBatchSize
            minOperatorStake
        );

        // Deploy HeartbeatManager
        deployed.manager = new HeartbeatManager(deployed.config, deployer);

        // Deploy RewardPolicy
        deployed.rewardPolicy = new RewardPolicy(
            IERC20(address(deployed.token)),
            address(deployed.manager),
            deployer,
            1 days, // epochDuration
            0 // maxPayoutPerFinalize (0 = unlimited)
        );

        // Deploy Slashing Policy
        if (useNoOpSlashing) {
            NoOpSlashingPolicy noOpPolicy = new NoOpSlashingPolicy();
            deployed.slashingPolicy = address(noOpPolicy);
        } else {
            JailingPolicy jailingPolicy = new JailingPolicy(address(deployed.manager));
            deployed.slashingPolicy = address(jailingPolicy);
        }

        // Wire everything together
        // Update ProtocolConfig with real modules
        deployed.config.setModules(
            address(deployed.stakingOps),
            address(deployed.selector),
            deployed.slashingPolicy,
            address(deployed.rewardPolicy)
        );

        // Configure StakingOperators
        deployed.stakingOps.setProtocolConfig(deployed.config);
        deployed.stakingOps.setHeartbeatManager(address(deployed.manager));
        deployed.stakingOps.setSnapshotter(address(deployed.manager));

        // Grant SLASHER_ROLE to slashing policy
        if (!useNoOpSlashing) {
            deployed.stakingOps.grantRole(
                deployed.stakingOps.SLASHER_ROLE(),
                deployed.slashingPolicy
            );
        }

        // Deploy EmissionsController
        if (deployEmissions) {
            // Deploy mock bridge for testing
            deployed.mockBridge = new MockL1StandardBridge();

            // Example emissions schedule: 1000 tokens per epoch for 10 epochs
            uint256[] memory emissionsSchedule = new uint256[](10);
            for (uint256 i = 0; i < 10; i++) {
                emissionsSchedule[i] = 1000e18;
            }

            deployed.emissionsController = new EmissionsController(
                IERC20Mintable(address(deployed.token)),
                IL1StandardBridge(address(deployed.mockBridge)),
                address(deployed.token), // l2Token (same for testing)
                address(deployed.rewardPolicy), // l2Recipient
                block.timestamp, // startTime
                7 days, // epochDuration
                200000, // l2GasLimit
                10000e18, // globalMintCap
                emissionsSchedule,
                deployer
            );
        }

        vm.stopBroadcast();

        // Write contract addresses to .env file
        _writeContractAddresses(deployed, deployEmissions);

        return deployed;
    }

    function _writeContractAddresses(
        DeployedContracts memory deployed,
        bool emissionsDeployed
    ) internal {
        string memory output = "# Blacklight Contract Addresses\n";
        output = string.concat(output, "# Generated by DeployBlacklight.s.sol\n\n");

        output = string.concat(output, "STAKE_TOKEN=", vm.toString(address(deployed.token)), "\n");
        output = string.concat(output, "STAKING_OPERATORS=", vm.toString(address(deployed.stakingOps)), "\n");
        output = string.concat(output, "WEIGHTED_COMMITTEE_SELECTOR=", vm.toString(address(deployed.selector)), "\n");
        output = string.concat(output, "PROTOCOL_CONFIG=", vm.toString(address(deployed.config)), "\n");
        output = string.concat(output, "HEARTBEAT_MANAGER=", vm.toString(address(deployed.manager)), "\n");
        output = string.concat(output, "REWARD_POLICY=", vm.toString(address(deployed.rewardPolicy)), "\n");
        output = string.concat(output, "SLASHING_POLICY=", vm.toString(deployed.slashingPolicy), "\n");

        if (emissionsDeployed) {
            output = string.concat(output, "EMISSIONS_CONTROLLER=", vm.toString(address(deployed.emissionsController)), "\n");
            output = string.concat(output, "MOCK_L1_STANDARD_BRIDGE=", vm.toString(address(deployed.mockBridge)), "\n");
        }

        vm.writeFile("contract_addresses.env", output);
    }
}
