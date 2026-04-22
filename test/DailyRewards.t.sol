// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import "../src/DailyRewards.sol";
import "../src/SimpleStaking.sol";
import "../src/mocks/MockERC20.sol";

contract DailyRewardsTest is Test {
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    SimpleStaking staking;
    DailyRewards rewards;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        stakeToken = new MockERC20("STAKE", "STK");
        rewardToken = new MockERC20("REWARD", "RWD");

        staking = new SimpleStaking(IERC20(address(stakeToken)), address(this), 1, 1 days);
        rewards =
            new DailyRewards(IERC20(address(rewardToken)), ISimpleStaking(address(staking)), address(this), 4 days);
        staking.setRewardNotifier(address(rewards));

        stakeToken.mint(alice, 1_000);
        stakeToken.mint(bob, 1_000);

        vm.startPrank(alice);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.stopPrank();

        vm.roll(2);
    }

    function test_checkpoint_distributesUnlockedRewardsProRata() public {
        vm.prank(alice);
        staking.stake(100);

        vm.prank(bob);
        staking.stake(300);

        rewardToken.mint(address(rewards), 400);
        rewards.sync();

        vm.warp(1 days + 1);
        vm.roll(3);
        rewards.checkpoint();

        assertEq(rewards.rewards(alice), 24);
        assertEq(rewards.rewards(bob), 74);

        vm.prank(alice);
        rewards.claim();
        vm.prank(bob);
        rewards.claim();

        assertEq(rewardToken.balanceOf(alice), 24);
        assertEq(rewardToken.balanceOf(bob), 74);

        vm.expectRevert(abi.encodeWithSelector(DailyRewards.AlreadyCheckpointed.selector, uint64(1), uint64(1)));
        rewards.checkpoint();
    }

    function test_stakeChangesPreservePriorCheckpointRewards() public {
        vm.prank(alice);
        staking.stake(100);

        rewardToken.mint(address(rewards), 400);
        rewards.sync();

        vm.warp(1 days + 1);
        vm.roll(3);
        rewards.checkpoint();

        assertEq(rewards.rewards(alice), 99);

        vm.prank(alice);
        staking.requestUnstake(50);

        vm.prank(bob);
        staking.stake(50);

        vm.warp(2 days + 2);
        vm.roll(4);
        rewards.checkpoint();

        assertEq(rewards.rewards(alice), 149);
        assertEq(rewards.rewards(bob), 50);
    }

    function test_checkpoint_carriesForwardUntilStakeExists() public {
        rewardToken.mint(address(rewards), 200);
        rewards.sync();

        vm.warp(1 days + 1);
        vm.roll(3);
        rewards.checkpoint();

        assertEq(rewards.spendableBudget(), 49);

        vm.prank(alice);
        staking.stake(100);

        vm.warp(2 days + 2);
        vm.roll(4);
        rewards.checkpoint();

        assertEq(rewards.rewards(alice), 99);
    }

    function test_accrueWeights_isUnsupported() public {
        address[] memory recipients = new address[](0);
        uint256[] memory weights = new uint256[](0);

        vm.expectRevert(DailyRewards.UnsupportedAccrual.selector);
        rewards.accrueWeights(bytes32(0), 0, recipients, weights);
    }
}
