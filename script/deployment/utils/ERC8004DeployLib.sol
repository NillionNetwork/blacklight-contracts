// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/console.sol";
import "forge-std/Vm.sol";

import {IdentityRegistryUpgradeable} from "../../../src/erc-8004/IdentityRegistryUpgradeable.sol";
import {ValidationRegistryUpgradeable} from "../../../src/erc-8004/ValidationRegistryUpgradeable.sol";
import {ReputationRegistryUpgradeable} from "../../../src/erc-8004/ReputationRegistryUpgradeable.sol";
import {HardhatMinimalUUPS} from "../../../src/erc-8004/HardhatMinimalUUPS.sol";
import {ERC1967Proxy} from "../../../src/erc-8004/ERC1967Proxy.sol";
import {HeartbeatManager} from "../../../src/HeartbeatManager.sol";

library ERC8004DeployLib {
    struct ERC8004Contracts {
        HardhatMinimalUUPS minimalImpl;
        IdentityRegistryUpgradeable identityImpl;
        ValidationRegistryUpgradeable validationImpl;
        ReputationRegistryUpgradeable reputationImpl;
        IdentityRegistryUpgradeable identity;
        ValidationRegistryUpgradeable validation;
        ReputationRegistryUpgradeable reputation;
        bool reputationDeployed;
    }

    function deploy(address deployer, address heartbeatManager, bool deployReputation, bool skipHeartbeatRole)
        internal
        returns (ERC8004Contracts memory deployed)
    {
        deployed.reputationDeployed = deployReputation;

        deployed.minimalImpl = new HardhatMinimalUUPS();

        deployed.identityImpl = new IdentityRegistryUpgradeable();
        bytes memory initData = abi.encodeCall(HardhatMinimalUUPS.initialize, (address(0)));
        ERC1967Proxy identityProxy = new ERC1967Proxy(address(deployed.minimalImpl), initData);
        HardhatMinimalUUPS(address(identityProxy)).upgradeToAndCall(
            address(deployed.identityImpl), abi.encodeCall(IdentityRegistryUpgradeable.initialize, ())
        );
        deployed.identity = IdentityRegistryUpgradeable(address(identityProxy));

        deployed.validationImpl = new ValidationRegistryUpgradeable();
        initData = abi.encodeCall(HardhatMinimalUUPS.initialize, (address(deployed.identity)));
        ERC1967Proxy validationProxy = new ERC1967Proxy(address(deployed.minimalImpl), initData);
        HardhatMinimalUUPS(address(validationProxy)).upgradeToAndCall(
            address(deployed.validationImpl),
            abi.encodeCall(ValidationRegistryUpgradeable.initialize, (address(deployed.identity)))
        );
        deployed.validation = ValidationRegistryUpgradeable(address(validationProxy));

        if (heartbeatManager != address(0)) {
            deployed.validation.setHeartbeatManager(heartbeatManager);

            if (!skipHeartbeatRole) {
                HeartbeatManager hm = HeartbeatManager(heartbeatManager);
                bytes32 submitterRole = hm.HEARTBEAT_SUBMITTER_ROLE();
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

        if (deployReputation) {
            deployed.reputationImpl = new ReputationRegistryUpgradeable();
            initData = abi.encodeCall(HardhatMinimalUUPS.initialize, (address(deployed.identity)));
            ERC1967Proxy reputationProxy = new ERC1967Proxy(address(deployed.minimalImpl), initData);
            HardhatMinimalUUPS(address(reputationProxy)).upgradeToAndCall(
                address(deployed.reputationImpl),
                abi.encodeCall(ReputationRegistryUpgradeable.initialize, (address(deployed.identity)))
            );
            deployed.reputation = ReputationRegistryUpgradeable(address(reputationProxy));
        }

        console.log("=== ERC-8004 Deployment ===");
        console.log("MinimalUUPS Implementation:", address(deployed.minimalImpl));
        console.log("IdentityRegistry Impl:", address(deployed.identityImpl));
        console.log("IdentityRegistry:", address(deployed.identity));
        console.log("ValidationRegistry Impl:", address(deployed.validationImpl));
        console.log("ValidationRegistry:", address(deployed.validation));
        if (heartbeatManager != address(0)) {
            console.log("HeartbeatManager:", heartbeatManager);
        }
        if (deployReputation) {
            console.log("ReputationRegistry Impl:", address(deployed.reputationImpl));
            console.log("ReputationRegistry:", address(deployed.reputation));
        }
    }

    function writeContractAddresses(
        Vm vm,
        ERC8004Contracts memory deployed,
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
            output =
                string.concat(output, "REPUTATION_REGISTRY_IMPL=", vm.toString(address(deployed.reputationImpl)), "\n");
            output = string.concat(output, "REPUTATION_REGISTRY=", vm.toString(address(deployed.reputation)), "\n");
        }

        vm.writeFile("erc8004_addresses.env", output);
    }
}
