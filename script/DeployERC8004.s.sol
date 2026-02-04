// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {IdentityRegistryUpgradeable} from "../src/erc-8004/IdentityRegistryUpgradeable.sol";
import {ValidationRegistryUpgradeable} from "../src/erc-8004/ValidationRegistryUpgradeable.sol";
import {ReputationRegistryUpgradeable} from "../src/erc-8004/ReputationRegistryUpgradeable.sol";
import {HardhatMinimalUUPS} from "../src/erc-8004/HardhatMinimalUUPS.sol";
import {ERC1967Proxy} from "../src/erc-8004/ERC1967Proxy.sol";
import {HeartbeatManager} from "../src/HeartbeatManager.sol";

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
    struct DeployedContracts {
        // Shared minimal implementation
        HardhatMinimalUUPS minimalImpl;
        // Implementations
        IdentityRegistryUpgradeable identityImpl;
        ValidationRegistryUpgradeable validationImpl;
        ReputationRegistryUpgradeable reputationImpl;
        // Proxies (typed as final implementation)
        IdentityRegistryUpgradeable identity;
        ValidationRegistryUpgradeable validation;
        ReputationRegistryUpgradeable reputation;
    }

    function run() external returns (DeployedContracts memory deployed) {
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

        // ============================================
        // Step 1: Deploy shared MinimalUUPS implementation
        // ============================================
        deployed.minimalImpl = new HardhatMinimalUUPS();
        console.log("MinimalUUPS Implementation:", address(deployed.minimalImpl));

        // ============================================
        // Step 2: Deploy IdentityRegistry
        // ============================================
        console.log("");
        console.log("--- IdentityRegistry ---");

        // Deploy implementation
        deployed.identityImpl = new IdentityRegistryUpgradeable();
        console.log("Implementation:", address(deployed.identityImpl));

        // Deploy proxy with MinimalUUPS, initialize with address(0) since Identity doesn't need it
        bytes memory initData = abi.encodeCall(HardhatMinimalUUPS.initialize, (address(0)));
        ERC1967Proxy identityProxy = new ERC1967Proxy(address(deployed.minimalImpl), initData);
        console.log("Proxy:", address(identityProxy));

        // Upgrade to real implementation
        HardhatMinimalUUPS(address(identityProxy)).upgradeToAndCall(
            address(deployed.identityImpl),
            abi.encodeCall(IdentityRegistryUpgradeable.initialize, ())
        );

        // Cast to final type
        deployed.identity = IdentityRegistryUpgradeable(address(identityProxy));
        console.log("Version:", deployed.identity.getVersion());
        console.log("Owner:", deployed.identity.owner());

        // ============================================
        // Step 3: Deploy ValidationRegistry
        // ============================================
        console.log("");
        console.log("--- ValidationRegistry ---");

        // Deploy implementation
        deployed.validationImpl = new ValidationRegistryUpgradeable();
        console.log("Implementation:", address(deployed.validationImpl));

        // Deploy proxy with MinimalUUPS, initialize with IdentityRegistry address
        initData = abi.encodeCall(HardhatMinimalUUPS.initialize, (address(deployed.identity)));
        ERC1967Proxy validationProxy = new ERC1967Proxy(address(deployed.minimalImpl), initData);
        console.log("Proxy:", address(validationProxy));

        // Upgrade to real implementation
        HardhatMinimalUUPS(address(validationProxy)).upgradeToAndCall(
            address(deployed.validationImpl),
            abi.encodeCall(ValidationRegistryUpgradeable.initialize, (address(deployed.identity)))
        );

        // Cast to final type
        deployed.validation = ValidationRegistryUpgradeable(address(validationProxy));
        console.log("Version:", deployed.validation.getVersion());
        console.log("Owner:", deployed.validation.owner());
        console.log("IdentityRegistry:", deployed.validation.getIdentityRegistry());

        // Connect to HeartbeatManager if provided
        if (heartbeatManager != address(0)) {
            deployed.validation.setHeartbeatManager(heartbeatManager);
            console.log("HeartbeatManager:", heartbeatManager);

            // Grant HEARTBEAT_SUBMITTER_ROLE to ValidationRegistry on HeartbeatManager
            if (!skipHeartbeatRole) {
                HeartbeatManager hm = HeartbeatManager(heartbeatManager);
                bytes32 submitterRole = hm.HEARTBEAT_SUBMITTER_ROLE();

                // Check if deployer has admin role to grant
                bytes32 adminRole = hm.HEARTBEAT_SUBMITTER_ADMIN_ROLE();
                if (hm.hasRole(adminRole, deployer) || hm.hasRole(hm.DEFAULT_ADMIN_ROLE(), deployer)) {
                    hm.grantRole(submitterRole, address(deployed.validation));
                    console.log("Granted HEARTBEAT_SUBMITTER_ROLE to ValidationRegistry");
                } else {
                    console.log("WARNING: Deployer lacks admin role, cannot grant HEARTBEAT_SUBMITTER_ROLE");
                    console.log("Please grant role manually:");
                    console.log("  HeartbeatManager.grantRole(HEARTBEAT_SUBMITTER_ROLE, ValidationRegistry)");
                }
            }
        }

        // ============================================
        // Step 4: Deploy ReputationRegistry (optional)
        // ============================================
        if (deployReputation) {
            console.log("");
            console.log("--- ReputationRegistry ---");

            // Deploy implementation
            deployed.reputationImpl = new ReputationRegistryUpgradeable();
            console.log("Implementation:", address(deployed.reputationImpl));

            // Deploy proxy with MinimalUUPS, initialize with IdentityRegistry address
            initData = abi.encodeCall(HardhatMinimalUUPS.initialize, (address(deployed.identity)));
            ERC1967Proxy reputationProxy = new ERC1967Proxy(address(deployed.minimalImpl), initData);
            console.log("Proxy:", address(reputationProxy));

            // Upgrade to real implementation
            HardhatMinimalUUPS(address(reputationProxy)).upgradeToAndCall(
                address(deployed.reputationImpl),
                abi.encodeCall(ReputationRegistryUpgradeable.initialize, (address(deployed.identity)))
            );

            // Cast to final type
            deployed.reputation = ReputationRegistryUpgradeable(address(reputationProxy));
            console.log("Version:", deployed.reputation.getVersion());
            console.log("Owner:", deployed.reputation.owner());
            console.log("IdentityRegistry:", deployed.reputation.getIdentityRegistry());
        }

        vm.stopBroadcast();

        // Write contract addresses to file
        _writeContractAddresses(deployed, deployReputation, heartbeatManager);

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Addresses written to: erc8004_addresses.env");

        return deployed;
    }

    function _writeContractAddresses(
        DeployedContracts memory deployed,
        bool reputationDeployed,
        address heartbeatManager
    ) internal {
        string memory output = "# ERC-8004 Contract Addresses\n";
        output = string.concat(output, "# Generated by DeployERC8004.s.sol\n\n");

        output = string.concat(output, "# Shared\n");
        output = string.concat(output, "MINIMAL_UUPS_IMPL=", vm.toString(address(deployed.minimalImpl)), "\n\n");

        output = string.concat(output, "# IdentityRegistry\n");
        output = string.concat(output, "IDENTITY_REGISTRY_IMPL=", vm.toString(address(deployed.identityImpl)), "\n");
        output = string.concat(output, "IDENTITY_REGISTRY=", vm.toString(address(deployed.identity)), "\n\n");

        output = string.concat(output, "# ValidationRegistry\n");
        output = string.concat(output, "VALIDATION_REGISTRY_IMPL=", vm.toString(address(deployed.validationImpl)), "\n");
        output = string.concat(output, "VALIDATION_REGISTRY=", vm.toString(address(deployed.validation)), "\n");
        if (heartbeatManager != address(0)) {
            output = string.concat(output, "VALIDATION_HEARTBEAT_MANAGER=", vm.toString(heartbeatManager), "\n");
        }
        output = string.concat(output, "\n");

        if (reputationDeployed) {
            output = string.concat(output, "# ReputationRegistry\n");
            output = string.concat(output, "REPUTATION_REGISTRY_IMPL=", vm.toString(address(deployed.reputationImpl)), "\n");
            output = string.concat(output, "REPUTATION_REGISTRY=", vm.toString(address(deployed.reputation)), "\n");
        }

        vm.writeFile("erc8004_addresses.env", output);
    }
}
