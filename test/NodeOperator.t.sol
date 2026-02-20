// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../src/NodeOperator.sol";
import "./helpers/BlacklightFixture.sol";

contract NodeOperatorTest is BlacklightFixture {
    NodeOperator internal nodeOp;

    address internal user1 = address(0x1001);
    address internal user2 = address(0x1002);
    address internal node1 = address(0xA001);

    uint256 constant STAKE_AMOUNT = 1_000_000e6; // 1M NIL

    function setUp() public {
        uint256[] memory stakes = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            stakes[i] = 100e18;
        }
        _deploySystem(3, stakes, 3, 100, 6700, 6700, 5 minutes, 2 minutes, 0);

        config.setParams(5, 0, 100, 0, 6700, 6700, 5 minutes, 2 minutes, 100, 1e6);

        nodeOp = new NodeOperator(
            address(this),
            STAKE_AMOUNT,
            node1,
            address(stakingOps),
            address(rewardPolicy),
            address(stakeToken),
            address(rewardToken)
        );

        vm.prank(node1);
        stakingOps.approveStaker(address(nodeOp));

        // Mint to test contract (acting as owner/factory)
        stakeToken.mint(address(this), 20_000_000e6);
    }

    /// @dev Mimics what the Factory does: transfer tokens to operator, then call stake
    function _stakeViaFactory(uint256 amount) internal {
        stakeToken.transfer(address(nodeOp), amount);
        nodeOp.stake();
    }

    function test_nodeConfigured() public view {
        assertEq(nodeOp.nodeAddress(), node1);
        assertEq(nodeOp.nodeUser(), address(0));
    }

    function test_assignAndStake() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        assertEq(nodeOp.nodeUser(), user1);
    }

    function test_secondUserCannotBeAssignedWhileNodeInUse() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        vm.expectRevert(NodeOperator.InvalidUserAssignment.selector);
        nodeOp.assignUser(user2);
    }

    function test_requestUnstakeAndWithdraw() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        nodeOp.requestUnstake(STAKE_AMOUNT);
        vm.warp(block.timestamp + stakingOps.unstakeDelay() + 1);
        nodeOp.withdrawUnstaked();

        assertEq(stakeToken.balanceOf(user1), STAKE_AMOUNT);
    }

    function test_minStakeEnforced() public {
        nodeOp.assignUser(user1);
        stakeToken.transfer(address(nodeOp), STAKE_AMOUNT - 1);
        vm.expectRevert(NodeOperator.BelowMinimumStake.selector);
        nodeOp.stake();
    }

    function test_directEntryPointsRevertForNonOwner() public {
        address outsider = address(0xDEAD);
        bytes memory expectedRevert = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider);

        vm.startPrank(outsider);

        vm.expectRevert(expectedRevert);
        nodeOp.stake();

        vm.expectRevert(expectedRevert);
        nodeOp.requestUnstake(STAKE_AMOUNT);

        vm.expectRevert(expectedRevert);
        nodeOp.withdrawUnstaked();

        vm.expectRevert(expectedRevert);
        nodeOp.harvestRewards();

        vm.expectRevert(expectedRevert);
        nodeOp.assignUser(user1);

        vm.stopPrank();
    }

    function test_rewardsHarvest() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        // Mint reward tokens directly to nodeOp since _harvestIfPossible
        // distributes the reward token balance
        rewardToken.mint(address(nodeOp), 1_000e6);
        nodeOp.harvestRewards();

        assertEq(rewardToken.balanceOf(user1), 1_000e6);
    }

    function test_rewardsHarvest_forwardsFeesImmediatelyAndOnlyOnNewRewards() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);
        nodeOp.setModeFeeBps(3000, 1500);

        rewardToken.mint(address(nodeOp), 1_000e6);
        nodeOp.harvestRewards();

        assertEq(rewardToken.balanceOf(user1), 700e6);
        assertEq(rewardToken.balanceOf(address(this)), 300e6);
        assertEq(rewardToken.balanceOf(address(nodeOp)), 0);

        // New rewards are fee-charged in isolation; no stale fee balance remains in operator.
        rewardToken.mint(address(nodeOp), 300e6);
        nodeOp.harvestRewards();

        assertEq(rewardToken.balanceOf(user1), 910e6); // +210
        assertEq(rewardToken.balanceOf(address(this)), 390e6); // +90
        assertEq(rewardToken.balanceOf(address(nodeOp)), 0);
    }

    function test_rewardsHarvest_restakeModeUsesRestakeFeeAndCompoundsStake() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        nodeOp.setRewardToken(address(stakeToken));
        nodeOp.setModeFeeBps(3000, 1500);
        nodeOp.setRewardBehavior(uint8(NodeOperator.RewardBehavior.AutoRestake));

        uint256 stakeBefore = stakingOps.stakeOf(node1);
        uint256 feeReceiverBefore = stakeToken.balanceOf(address(this));

        stakeToken.mint(address(nodeOp), 1_000e6);
        nodeOp.harvestRewards();

        assertEq(stakingOps.stakeOf(node1), stakeBefore + 850e6);
        assertEq(stakeToken.balanceOf(address(this)), feeReceiverBefore + 150e6);
        assertEq(stakeToken.balanceOf(user1), 0);
    }

    function test_setRewardBehavior_revertsWhenTokensDiffer() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        vm.expectRevert(NodeOperator.RestakeModeUnsupportedTokenPair.selector);
        nodeOp.setRewardBehavior(uint8(NodeOperator.RewardBehavior.AutoRestake));
    }

    function test_defaultRewardBehavior_isAutoRestakeWhenTokensMatch() public {
        NodeOperator restakeDefaultOp = new NodeOperator(
            address(this),
            STAKE_AMOUNT,
            node1,
            address(stakingOps),
            address(rewardPolicy),
            address(stakeToken),
            address(stakeToken)
        );
        assertEq(
            uint256(restakeDefaultOp.rewardBehavior()), uint256(uint8(NodeOperator.RewardBehavior.AutoRestake))
        );
    }

    function test_resetRewardBehavior_usesTokenPairDefault() public {
        NodeOperator restakeDefaultOp = new NodeOperator(
            address(this),
            STAKE_AMOUNT,
            node1,
            address(stakingOps),
            address(rewardPolicy),
            address(stakeToken),
            address(stakeToken)
        );

        restakeDefaultOp.setRewardBehavior(uint8(NodeOperator.RewardBehavior.WithdrawToUser));
        restakeDefaultOp.resetRewardBehavior();

        assertEq(
            uint256(restakeDefaultOp.rewardBehavior()), uint256(uint8(NodeOperator.RewardBehavior.AutoRestake))
        );
    }

    function test_assignUser_reappliesDefaultBehaviorAfterRelease() public {
        NodeOperator restakeDefaultOp = new NodeOperator(
            address(this),
            STAKE_AMOUNT,
            node1,
            address(stakingOps),
            address(rewardPolicy),
            address(stakeToken),
            address(stakeToken)
        );

        vm.prank(node1);
        stakingOps.approveStaker(address(restakeDefaultOp));

        restakeDefaultOp.assignUser(user1);
        stakeToken.transfer(address(restakeDefaultOp), STAKE_AMOUNT);
        restakeDefaultOp.stake();

        restakeDefaultOp.setRewardBehavior(uint8(NodeOperator.RewardBehavior.WithdrawToUser));
        restakeDefaultOp.requestUnstake(STAKE_AMOUNT);
        vm.warp(block.timestamp + stakingOps.unstakeDelay() + 1);
        restakeDefaultOp.withdrawUnstaked();

        restakeDefaultOp.assignUser(user2);

        assertEq(
            uint256(restakeDefaultOp.rewardBehavior()), uint256(uint8(NodeOperator.RewardBehavior.AutoRestake))
        );
    }

    function test_setModeFeeBps_setsModeFees() public {
        nodeOp.setModeFeeBps(1200, 800);
        assertEq(nodeOp.withdrawFeeBps(), 1200);
        assertEq(nodeOp.restakeFeeBps(), 800);
    }

    function test_partialUnstake_allowsSubMinimumRemainder() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        // Unstaking almost everything is allowed — user must always be able to exit
        uint256 partialAmount = STAKE_AMOUNT - 1;
        nodeOp.requestUnstake(partialAmount);
        assertEq(stakingOps.stakeOf(node1), 1);
    }

    function test_partialUnstake_allowsFullUnstake() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        nodeOp.requestUnstake(STAKE_AMOUNT);
    }

    function test_partialUnstake_allowsWhenRemainingAboveMinStake() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT * 3);

        nodeOp.requestUnstake(STAKE_AMOUNT);
        assertEq(stakingOps.stakeOf(node1), STAKE_AMOUNT * 2);
    }

    function test_partialUnstakeAndWithdraw_nodeStaysAssigned() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT * 3);

        // Partial unstake
        nodeOp.requestUnstake(STAKE_AMOUNT);
        vm.warp(block.timestamp + stakingOps.unstakeDelay() + 1);
        nodeOp.withdrawUnstaked();

        // Node should still be assigned (user still has active stake)
        assertEq(nodeOp.nodeUser(), user1);
        assertEq(stakeToken.balanceOf(user1), STAKE_AMOUNT);
    }

    function test_setModeFeeBps_revertsAboveMaxCap() public {
        vm.expectRevert(NodeOperator.FeeTooHigh.selector);
        nodeOp.setModeFeeBps(10001, 0);

        vm.expectRevert(NodeOperator.FeeTooHigh.selector);
        nodeOp.setModeFeeBps(0, 10001);
    }

    function test_harvestRevertsIfRewardModulesUnset() public {
        NodeOperator fresh = new NodeOperator(
            address(this),
            STAKE_AMOUNT,
            node1,
            address(stakingOps),
            address(0), // no rewardPolicy
            address(stakeToken),
            address(0) // no rewardToken
        );
        vm.expectRevert(NodeOperator.ContractNotConfigured.selector);
        fresh.harvestRewards();
    }
}
