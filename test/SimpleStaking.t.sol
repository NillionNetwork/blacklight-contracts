// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import "../src/SimpleStaking.sol";
import "../src/mocks/MockERC20.sol";

contract NoOpNotifier is ISimpleStakingRewardNotifier {
    function onStakeBalanceChanged(address, uint256, uint256) external {}
}

contract SimpleStakingTest is Test {
    MockERC20 token;
    SimpleStaking staking;
    NoOpNotifier notifier;

    address alice = address(0xA11CE);

    function setUp() public {
        token = new MockERC20("STAKE", "STK");
        staking = new SimpleStaking(IERC20(address(token)), address(this), 100, 1 days);
        notifier = new NoOpNotifier();

        token.mint(alice, 1_000);
        vm.startPrank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.stopPrank();

        vm.roll(2);
    }

    function test_stake_revertsBelowMinStake() public {
        vm.prank(alice);
        vm.expectRevert(SimpleStaking.BelowMinimumStake.selector);
        staking.stake(99);
    }

    function test_requestUnstake_and_withdraw_updatesActiveTotals() public {
        vm.prank(alice);
        staking.stake(200);

        assertEq(staking.stakeOf(alice), 200);
        assertEq(staking.totalStaked(), 200);

        vm.prank(alice);
        staking.requestUnstake(50);

        assertEq(staking.stakeOf(alice), 150);
        assertEq(staking.totalStaked(), 150);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        staking.withdrawUnstaked();

        assertEq(token.balanceOf(alice), 850);
        assertEq(staking.stakeOf(alice), 150);
        assertEq(staking.totalStaked(), 150);
    }

    function test_requestUnstake_revertsWhenRemainingStakeFallsBelowMin() public {
        vm.prank(alice);
        staking.stake(200);

        vm.prank(alice);
        vm.expectRevert(SimpleStaking.BelowMinimumStake.selector);
        staking.requestUnstake(150);
    }

    function test_fullExit_isAllowed() public {
        vm.prank(alice);
        staking.stake(200);

        vm.prank(alice);
        staking.requestUnstake(200);

        assertEq(staking.stakeOf(alice), 0);
        assertEq(staking.totalStaked(), 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        staking.withdrawUnstaked();

        assertEq(token.balanceOf(alice), 1_000);
    }

    function test_snapshot_readsPriorBlockStake() public {
        vm.prank(alice);
        staking.stake(200);

        vm.roll(block.number + 1);
        uint64 snapshotId = staking.snapshot();

        assertEq(staking.snapshotBlock(snapshotId), block.number - 1);
        assertEq(staking.stakeAt(alice, snapshotId), 200);
        assertEq(staking.totalStakedAt(snapshotId), 200);
    }

    function test_setRewardNotifier_revertsOnceStakeExists() public {
        staking.setRewardNotifier(address(notifier));
        assertEq(staking.rewardNotifier(), address(notifier));

        vm.prank(alice);
        staking.stake(200);

        vm.expectRevert(SimpleStaking.ActiveStakeExists.selector);
        staking.setRewardNotifier(address(0xCAFE));
    }
}
