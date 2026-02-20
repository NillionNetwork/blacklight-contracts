// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../../../src/mocks/TESTToken.sol";
import "../../../src/StakingOperators.sol";
import "../../../src/WeightedCommitteeSelector.sol";
import "../../../src/ProtocolConfig.sol";
import "../../../src/HeartbeatManager.sol";
import "../../../src/RewardPolicy.sol";
import {EmissionsController} from "../../../src/EmissionsController.sol";
import "../../../src/mocks/MockL1StandardBridge.sol";

library BlacklightTypes {
    struct CoreConfig {
        uint256 unstakeDelay;
        uint32 baseCommitteeSize;
        uint32 maxCommitteeSize;
        uint8 maxEscalations;
        uint16 quorumBps;
        uint16 verificationBps;
        uint256 responseWindow;
        uint256 jailDuration;
        uint256 minOperatorStake;
        uint256 minCommitteeVP;
        bool useNoOpSlashing;
    }

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
}
