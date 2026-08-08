// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../../../src/mocks/TESTToken.sol";
import "../../../src/StakingOperators.sol";
import "../../../src/WeightedCommitteeSelector.sol";
import "../../../src/ProtocolConfig.sol";
import "../../../src/HeartbeatManager.sol";
import "../../../src/RewardPolicy.sol";
import "../../../src/JailingPolicy.sol";
import "../../../src/NoOpSlashingPolicy.sol";
import {EmissionsController, IERC20Mintable, IL1StandardBridge} from "../../../src/EmissionsController.sol";
import "../../../src/mocks/MockL1StandardBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlacklightTypes} from "./BlacklightTypes.sol";

library BlacklightCoreDeployLib {
    function deployCore(address deployer, BlacklightTypes.CoreConfig memory cfg)
        internal
        returns (BlacklightTypes.DeployedContracts memory deployed)
    {
        deployed.token = new TESTToken(deployer);
        deployed.token.mint(deployer, 1_000_000_000e6);
        deployed.stakingOps = new StakingOperators(IERC20(address(deployed.token)), deployer, cfg.unstakeDelay);

        deployed.selector =
            new WeightedCommitteeSelector(deployed.stakingOps, deployer, cfg.minCommitteeVP, cfg.maxCommitteeSize);

        NoOpSlashingPolicy noOpSlashing = new NoOpSlashingPolicy();

        deployed.config = new ProtocolConfig(
            deployer,
            address(deployed.stakingOps),
            address(deployed.selector),
            address(noOpSlashing),
            address(noOpSlashing),
            cfg.baseCommitteeSize,
            0,
            cfg.maxCommitteeSize,
            cfg.maxEscalations,
            cfg.quorumBps,
            cfg.verificationBps,
            cfg.responseWindow,
            cfg.jailDuration,
            100,
            cfg.minOperatorStake
        );

        deployed.manager = new HeartbeatManager(deployed.config, deployer);

        deployed.rewardPolicy =
            new RewardPolicy(IERC20(address(deployed.token)), address(deployed.manager), deployer, 1 minutes, 0);

        deployed.config.setRewardPolicy(address(deployed.rewardPolicy));

        if (cfg.useNoOpSlashing) {
            deployed.slashingPolicy = address(noOpSlashing);
        } else {
            JailingPolicy jailingPolicy = new JailingPolicy(address(deployed.manager));
            deployed.slashingPolicy = address(jailingPolicy);
            deployed.config.setSlashingPolicy(deployed.slashingPolicy);
        }

        deployed.stakingOps.setProtocolConfig(deployed.config);
        deployed.stakingOps.setHeartbeatManager(address(deployed.manager));
        deployed.stakingOps.setSnapshotter(address(deployed.manager));

        if (!cfg.useNoOpSlashing) {
            deployed.stakingOps.grantRole(deployed.stakingOps.SLASHER_ROLE(), deployed.slashingPolicy);
        }
    }

    function deployEmissions(address deployer, TESTToken token, RewardPolicy rewardPolicy)
        internal
        returns (EmissionsController emissionsController, MockL1StandardBridge mockBridge)
    {
        mockBridge = new MockL1StandardBridge();

        uint256[] memory emissionsSchedule = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            emissionsSchedule[i] = 1000e18;
        }

        EmissionsController.Recipient memory sink =
            EmissionsController.Recipient({addr: address(rewardPolicy), bps: 0, isL2: true});
        EmissionsController.Recipient[] memory initial = new EmissionsController.Recipient[](0);

        emissionsController = new EmissionsController(
            IERC20Mintable(address(token)),
            IL1StandardBridge(address(mockBridge)),
            address(token),
            sink,
            initial,
            block.timestamp,
            7 days,
            200000,
            10000e18,
            emissionsSchedule,
            deployer
        );
    }
}
