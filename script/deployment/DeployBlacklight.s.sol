// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {BlacklightTypes} from "./utils/BlacklightTypes.sol";
import {BlacklightCoreDeployLib} from "./utils/BlacklightCoreDeployLib.sol";
import {BlacklightOutputLib} from "./utils/BlacklightOutputLib.sol";

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
///      - MIN_COMMITTEE_VP: Minimum voting power required for committee selection (default: 1)
///      - USE_NOOP_SLASHING: Set to "true" to use NoOpSlashingPolicy instead of JailingPolicy (default: false)
///      - DEPLOY_EMISSIONS: Set to "true" to deploy EmissionsController (default: false)
///      - NOTE: ERC-8004 and NodeManagers are deployed separately
contract DeployBlacklight is Script {
    function run() external returns (BlacklightTypes.DeployedContracts memory deployed) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Read configuration from environment or use defaults
        BlacklightTypes.CoreConfig memory coreCfg = BlacklightTypes.CoreConfig({
            unstakeDelay: vm.envOr("UNSTAKE_DELAY", uint256(1 minutes)),
            baseCommitteeSize: uint32(vm.envOr("BASE_COMMITTEE_SIZE", uint256(10))),
            maxCommitteeSize: uint32(vm.envOr("MAX_COMMITTEE_SIZE", uint256(200))),
            maxEscalations: uint8(vm.envOr("MAX_ESCALATIONS", uint256(3))),
            quorumBps: uint16(vm.envOr("QUORUM_BPS", uint256(9000))),
            verificationBps: uint16(vm.envOr("VERIFICATION_BPS", uint256(7000))),
            responseWindow: vm.envOr("RESPONSE_WINDOW", uint256(30 seconds)),
            jailDuration: vm.envOr("JAIL_DURATION", uint256(2 minutes)),
            minOperatorStake: vm.envOr("MIN_OPERATOR_STAKE", uint256(10e6)),
            minCommitteeVP: vm.envOr("MIN_COMMITTEE_VP", uint256(1)),
            useNoOpSlashing: vm.envOr("USE_NOOP_SLASHING", false)
        });
        bool deployEmissions = vm.envOr("DEPLOY_EMISSIONS", false);

        vm.startBroadcast(deployerPrivateKey);

        deployed = BlacklightCoreDeployLib.deployCore(deployer, coreCfg);

        // Deploy EmissionsController
        if (deployEmissions) {
            (deployed.emissionsController, deployed.mockBridge) =
                BlacklightCoreDeployLib.deployEmissions(deployer, deployed.token, deployed.rewardPolicy);
        }

        vm.stopBroadcast();

        bool writeOutput = vm.envOr("WRITE_OUTPUT", true);
        if (writeOutput) {
            // Write contract addresses to .env file
            BlacklightOutputLib.writeContractAddresses(vm, deployed, deployEmissions);
        }

        return deployed;
    }
}
