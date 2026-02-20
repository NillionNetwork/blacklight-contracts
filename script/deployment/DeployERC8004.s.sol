// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ERC8004DeployLib} from "./utils/ERC8004DeployLib.sol";

/// @title DeployERC8004
/// @notice Deploys the ERC-8004 registry contracts (Identity, Validation, Reputation)
/// @dev Uses the UUPS upgrade pattern: MinimalUUPS -> Real Implementation
///
/// Configurable via environment variables:
///      - PRIVATE_KEY: Deployer private key (required)
///      - HEARTBEAT_MANAGER: Address of existing HeartbeatManager to connect ValidationRegistry (optional)
///      - DEPLOY_REPUTATION: Set to "true" to deploy ReputationRegistry (default: true)
///      - SKIP_HEARTBEAT_ROLE: Set to "true" to skip granting HEARTBEAT_SUBMITTER_ROLE (default: false)
///
/// Deployment pattern for each registry:
///      1. Deploy HardhatMinimalUUPS implementation (shared)
///      2. Deploy real implementation (Identity/Validation/Reputation)
///      3. Deploy ERC1967Proxy pointing to MinimalUUPS with initialize call
///      4. Upgrade proxy to real implementation
///      5. Call reinitializer on real implementation
contract DeployERC8004 is Script {
    function run() external returns (ERC8004DeployLib.ERC8004Contracts memory deployed) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Read configuration from environment
        address heartbeatManager = vm.envOr("HEARTBEAT_MANAGER", address(0));
        bool deployReputation = vm.envOr("DEPLOY_REPUTATION", true);
        bool skipHeartbeatRole = vm.envOr("SKIP_HEARTBEAT_ROLE", false);

        console.log("=== ERC-8004 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("HeartbeatManager:", heartbeatManager);
        console.log("Deploy Reputation:", deployReputation);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);
        deployed = ERC8004DeployLib.deploy(deployer, heartbeatManager, deployReputation, skipHeartbeatRole);

        vm.stopBroadcast();

        bool writeOutput = vm.envOr("WRITE_OUTPUT", true);
        if (writeOutput) {
            // Write contract addresses to file
            ERC8004DeployLib.writeContractAddresses(vm, deployed, deployReputation, heartbeatManager);
        }

        console.log("");
        console.log("=== Deployment Complete ===");
        if (writeOutput) {
            console.log("Addresses written to: erc8004_addresses.env");
        } else {
            console.log("Dry-run mode: skipped writing erc8004_addresses.env");
        }

        return deployed;
    }
}
