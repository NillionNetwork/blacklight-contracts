// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/mocks/TESTToken.sol";
import "../../src/SimpleStaking.sol";
import "../../src/DailyRewards.sol";

/// @notice Deploys the simplified staking + daily rewards suite for the new project.
/// @dev Configure via env vars:
///      - PRIVATE_KEY (required)
///      - OWNER (defaults to deployer)
///      - USE_MOCK_TOKENS (bool, default false)
///      - STAKING_TOKEN / REWARD_TOKEN (optional when using mocks)
///      - MINT_RECIPIENT (defaults to OWNER)
///      - MOCK_STAKE_MINT / MOCK_REWARD_MINT (uints, only used when deploying TEST tokens)
///      - MIN_STAKE
///      - UNSTAKE_DELAY_SEC
///      - REWARD_EPOCH_DURATION
contract DeployProjectSuite is Script {
    struct Params {
        uint256 deployerKey;
        address deployer;
        address owner;
        bool useMockTokens;
        address stakingToken;
        address rewardToken;
        address mintRecipient;
        uint256 mockStakeMint;
        uint256 mockRewardMint;
        uint256 minStake;
        uint256 unstakeDelay;
        uint256 rewardEpochDuration;
    }

    function run() external {
        Params memory p = _readParams();

        vm.startBroadcast(p.deployerKey);

        address stakingToken = p.stakingToken;
        address rewardToken = p.rewardToken;

        if (p.useMockTokens) {
            if (stakingToken == address(0)) {
                TESTToken mockStake = new TESTToken(p.owner);
                stakingToken = address(mockStake);
                if (p.mockStakeMint != 0) mockStake.mint(p.mintRecipient, p.mockStakeMint);
                console2.log("Deployed TEST staking token:", stakingToken);
            }

            if (rewardToken == address(0)) {
                TESTToken mockReward = new TESTToken(p.owner);
                rewardToken = address(mockReward);
                if (p.mockRewardMint != 0) mockReward.mint(p.mintRecipient, p.mockRewardMint);
                console2.log("Deployed TEST reward token:", rewardToken);
            }
        }

        if (stakingToken == address(0)) revert("staking token required");
        if (rewardToken == address(0)) rewardToken = stakingToken;

        SimpleStaking staking = new SimpleStaking(IERC20(stakingToken), p.owner, p.minStake, p.unstakeDelay);
        DailyRewards rewards =
            new DailyRewards(IERC20(rewardToken), ISimpleStaking(address(staking)), p.owner, p.rewardEpochDuration);
        staking.setRewardNotifier(address(rewards));

        vm.stopBroadcast();

        console2.log("--- Project suite deployment complete ---");
        console2.log("Owner:", p.owner);
        console2.log("Staking token:", stakingToken);
        console2.log("Reward token:", rewardToken);
        console2.log("SimpleStaking:", address(staking));
        console2.log("DailyRewards:", address(rewards));
    }

    function _readParams() internal view returns (Params memory p) {
        p.deployerKey = vm.envUint("PRIVATE_KEY");
        p.deployer = vm.addr(p.deployerKey);
        p.owner = vm.envOr("OWNER", p.deployer);

        p.useMockTokens = vm.envOr("USE_MOCK_TOKENS", false);
        p.stakingToken = vm.envOr("STAKING_TOKEN", address(0));
        p.rewardToken = vm.envOr("REWARD_TOKEN", address(0));
        p.mintRecipient = vm.envOr("MINT_RECIPIENT", p.owner);
        p.mockStakeMint = vm.envOr("MOCK_STAKE_MINT", uint256(1_000_000e18));
        p.mockRewardMint = vm.envOr("MOCK_REWARD_MINT", uint256(1_000_000e18));
        p.minStake = vm.envOr("MIN_STAKE", uint256(1e18));
        p.unstakeDelay = vm.envOr("UNSTAKE_DELAY_SEC", uint256(7 days));
        p.rewardEpochDuration = vm.envOr("REWARD_EPOCH_DURATION", uint256(30 days));
    }
}
