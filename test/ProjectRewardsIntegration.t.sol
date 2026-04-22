// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import "../src/DailyRewards.sol";
import "../src/EmissionsController.sol";
import "../src/SimpleStaking.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockL1StandardBridge.sol";

contract ProjectRewardsIntegrationTest is Test {
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    SimpleStaking staking;
    DailyRewards rewards;
    MockL1StandardBridge bridge;
    EmissionsController controller;

    address alice = address(0xA11CE);

    function setUp() public {
        stakeToken = new MockERC20("STAKE", "STK");
        rewardToken = new MockERC20("REWARD", "RWD");

        staking = new SimpleStaking(IERC20(address(stakeToken)), address(this), 1, 1 days);
        rewards =
            new DailyRewards(IERC20(address(rewardToken)), ISimpleStaking(address(staking)), address(this), 1 days);
        staking.setRewardNotifier(address(rewards));

        bridge = new MockL1StandardBridge();

        uint256[] memory schedule = new uint256[](1);
        schedule[0] = 120;

        EmissionsController.Recipient memory sink =
            EmissionsController.Recipient({addr: address(0xF00D), bps: 0, isL2: false});
        EmissionsController.Recipient[] memory recipients = new EmissionsController.Recipient[](1);
        recipients[0] = EmissionsController.Recipient({addr: address(rewards), bps: 10_000, isL2: false});

        controller = new EmissionsController(
            IERC20Mintable(address(rewardToken)),
            IL1StandardBridge(address(bridge)),
            address(rewardToken),
            sink,
            recipients,
            block.timestamp + 1,
            1 days,
            200_000,
            120,
            schedule,
            address(this)
        );

        stakeToken.mint(alice, 1_000);
        vm.startPrank(alice);
        stakeToken.approve(address(staking), type(uint256).max);
        staking.stake(100);
        vm.stopPrank();

        vm.roll(2);
    }

    function test_emissions_can_fund_daily_rewards_and_be_claimed() public {
        vm.warp(controller.nextEpochReadyAt());
        controller.mintAndBridgeNextEpoch();

        assertEq(rewardToken.balanceOf(address(rewards)), 120);

        rewards.sync();

        vm.warp(1 days + 3);
        vm.roll(3);
        rewards.checkpoint();

        assertEq(rewards.rewards(alice), 120);

        vm.prank(alice);
        rewards.claim();

        assertEq(rewardToken.balanceOf(alice), 120);
    }
}
