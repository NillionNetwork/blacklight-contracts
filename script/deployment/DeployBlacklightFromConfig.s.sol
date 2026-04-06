// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {BlacklightTypes} from "./utils/BlacklightTypes.sol";
import {BlacklightCoreDeployLib} from "./utils/BlacklightCoreDeployLib.sol";
import {BlacklightOutputLib} from "./utils/BlacklightOutputLib.sol";

/// @title DeployBlacklightFromConfig
/// @notice Deploys the Blacklight core suite from a typed JSON config file.
/// @dev The deployer key is still provided as PRIVATE_KEY env var.
contract DeployBlacklightFromConfig is Script {
    using stdJson for string;

    function run(string calldata configPath) external returns (BlacklightTypes.DeployedContracts memory deployed) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        string memory raw = vm.readFile(configPath);

        BlacklightTypes.CoreConfig memory coreCfg = BlacklightTypes.CoreConfig({
            unstakeDelay: raw.readUint(".unstakeDelay"),
            baseCommitteeSize: uint32(raw.readUint(".baseCommitteeSize")),
            maxCommitteeSize: uint32(raw.readUint(".maxCommitteeSize")),
            maxEscalations: uint8(raw.readUint(".maxEscalations")),
            quorumBps: uint16(raw.readUint(".quorumBps")),
            verificationBps: uint16(raw.readUint(".verificationBps")),
            responseWindow: raw.readUint(".responseWindow"),
            jailDuration: raw.readUint(".jailDuration"),
            minOperatorStake: raw.readUint(".minOperatorStake"),
            minCommitteeVP: raw.readUint(".minCommitteeVP"),
            useNoOpSlashing: raw.readBool(".useNoOpSlashing")
        });

        bool deployEmissions = raw.readBool(".deployEmissions");

        vm.startBroadcast(deployerPrivateKey);

        deployed = BlacklightCoreDeployLib.deployCore(deployer, coreCfg);

        if (deployEmissions) {
            (deployed.emissionsController, deployed.mockBridge) =
                BlacklightCoreDeployLib.deployEmissions(deployer, deployed.token, deployed.rewardPolicy);
        }

        vm.stopBroadcast();

        bool writeOutput = vm.envOr("WRITE_OUTPUT", true);
        if (writeOutput) {
            BlacklightOutputLib.writeContractAddresses(vm, deployed, deployEmissions);
        }

        return deployed;
    }
}
