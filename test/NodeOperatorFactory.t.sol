// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../src/NodeOperatorFactory.sol";
import "../src/NodeOperator.sol";
import "./helpers/BlacklightFixture.sol";

contract NodeOperatorFactoryTest is BlacklightFixture {
    NodeOperatorFactory internal factory;

    address internal userA = address(0x1111);
    address internal userB = address(0x2222);
    address internal nodeA = address(0xA001);
    address internal nodeB = address(0xB001);

    uint256 constant STAKE_AMOUNT = 1_000_000e6;

    function setUp() public {
        uint256[] memory stakes = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            stakes[i] = 100e18;
        }
        _deploySystem(5, stakes, 5, 100, 6700, 6700, 5 minutes, 2 minutes, 0);
        config.setParams(5, 0, 100, 0, 6700, 6700, 5 minutes, 2 minutes, 100, 1e6);

        factory = new NodeOperatorFactory(address(this));
        factory.setStakingOperators(address(stakingOps));
        factory.setRewardPolicy(address(rewardPolicy));
        factory.setStakingToken(address(stakeToken));
        factory.setRewardToken(address(rewardToken));
        factory.setDefaultModeFeeBps(0, 0);
        factory.setMinStake(STAKE_AMOUNT);
    }

    // ──────────────────────────────────────────────
    // addNode tests
    // ──────────────────────────────────────────────

    function test_addNode_deploysAndConfiguresNodeOperator() public {
        address opAddr = factory.addNode(nodeA);

        NodeOperator op = NodeOperator(opAddr);
        assertEq(op.owner(), address(factory));
        assertEq(op.nodeAddress(), nodeA);
        assertEq(address(op.stakingOperators()), address(stakingOps));
        assertEq(address(op.rewardPolicy()), address(rewardPolicy));
        assertEq(address(op.stakingToken()), address(stakeToken));
        assertEq(address(op.rewardToken()), address(rewardToken));
        assertEq(op.minStake(), STAKE_AMOUNT);
        assertEq(op.withdrawFeeBps(), 0);
        assertEq(op.restakeFeeBps(), 0);
        assertEq(uint256(op.rewardBehavior()), uint256(uint8(NodeOperator.RewardBehavior.WithdrawToUser)));

        assertEq(factory.nodeToOperator(nodeA), opAddr);
        assertEq(factory.operatorToNode(opAddr), nodeA);
        assertEq(factory.nodeCount(), 1);
        assertEq(factory.allNodes()[0], nodeA);
    }

    function test_addNode_revertsForNonOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xDEAD)));
        factory.addNode(nodeA);
    }

    function test_addNode_revertsForDuplicateNode() public {
        factory.addNode(nodeA);
        vm.expectRevert(NodeOperatorFactory.NodeAlreadyRegistered.selector);
        factory.addNode(nodeA);
    }

    function test_addNode_revertsWhenFactoryNotConfigured() public {
        NodeOperatorFactory unconfigured = new NodeOperatorFactory(address(this));
        vm.expectRevert(NodeOperatorFactory.FactoryNotConfigured.selector);
        unconfigured.addNode(nodeA);
    }

    // ──────────────────────────────────────────────
    // removeNode tests
    // ──────────────────────────────────────────────

    function test_removeNode_whenFree() public {
        address opAddr = factory.addNode(nodeA);
        assertEq(factory.nodeCount(), 1);

        factory.removeNode(nodeA);
        assertEq(factory.nodeCount(), 0);
        assertEq(factory.nodeToOperator(nodeA), address(0));
        assertEq(factory.operatorToNode(opAddr), address(0));
    }

    function test_removeNode_revertsWhenAssigned() public {
        address opAddr = factory.addNode(nodeA);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAddr);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);

        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        vm.expectRevert(NodeOperatorFactory.NodeCurrentlyAssigned.selector);
        factory.removeNode(nodeA);
    }

    function test_removeNode_revertsForUnregisteredNode() public {
        vm.expectRevert(NodeOperatorFactory.NodeNotRegistered.selector);
        factory.removeNode(nodeA);
    }

    // ──────────────────────────────────────────────
    // stake auto-binding tests
    // ──────────────────────────────────────────────

    function test_stake_autoBindsUserToFreeNode() public {
        address opAddr = factory.addNode(nodeA);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAddr);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);

        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        assertEq(factory.userToOperator(userA), opAddr);
        assertEq(factory.userToNode(userA), nodeA);
        assertEq(factory.nodeToUser(nodeA), userA);
        assertFalse(factory.isFreeNode(nodeA));
    }

    function test_stake_secondUserBindsToDifferentNode() public {
        address opAAddr = factory.addNode(nodeA);
        address opBAddr = factory.addNode(nodeB);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAAddr);
        vm.prank(nodeB);
        stakingOps.approveStaker(opBAddr);

        stakeToken.mint(userA, 2_000_000e6);
        stakeToken.mint(userB, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userB);
        stakeToken.approve(address(factory), type(uint256).max);

        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);
        vm.prank(userB);
        factory.stake(STAKE_AMOUNT);

        address boundA = factory.userToOperator(userA);
        address boundB = factory.userToOperator(userB);
        assertTrue(boundA != boundB);
    }

    function test_stake_revertsNoFreeNodeOperator() public {
        address opAddr = factory.addNode(nodeA);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAddr);

        stakeToken.mint(userA, 2_000_000e6);
        stakeToken.mint(userB, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userB);
        stakeToken.approve(address(factory), type(uint256).max);

        // First user takes the only node
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        // Second user can't stake - no free nodes
        vm.prank(userB);
        vm.expectRevert(NodeOperatorFactory.NoFreeNodeOperator.selector);
        factory.stake(STAKE_AMOUNT);
    }

    // ──────────────────────────────────────────────
    // Isolated rewards test
    // ──────────────────────────────────────────────

    function test_isolatedRewards_twoUsersOnDifferentNodes() public {
        address opAAddr = factory.addNode(nodeA);
        address opBAddr = factory.addNode(nodeB);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAAddr);
        vm.prank(nodeB);
        stakingOps.approveStaker(opBAddr);

        stakeToken.mint(userA, 2_000_000e6);
        stakeToken.mint(userB, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userB);
        stakeToken.approve(address(factory), type(uint256).max);

        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);
        vm.prank(userB);
        factory.stake(STAKE_AMOUNT);

        // Mint reward tokens to each user's bound operator
        address boundOpA = factory.userToOperator(userA);
        address boundOpB = factory.userToOperator(userB);
        uint256 rewardA = 700e6;
        uint256 rewardB = 300e6;
        rewardToken.mint(boundOpA, rewardA);
        rewardToken.mint(boundOpB, rewardB);

        // Harvest distributes rewards from operator to nodeUser
        factory.harvestRewards(boundOpA);
        factory.harvestRewards(boundOpB);

        assertEq(rewardToken.balanceOf(userA), rewardA);
        assertEq(rewardToken.balanceOf(userB), rewardB);
    }

    function test_withdrawFees_ownerCanWithdrawHarvestedFees() public {
        factory.setDefaultModeFeeBps(3000, 1500);
        address opAddr = factory.addNode(nodeA);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAddr);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        rewardToken.mint(opAddr, 1_000e6);
        factory.harvestRewards(opAddr);

        assertEq(rewardToken.balanceOf(address(factory)), 300e6);
        assertEq(rewardToken.balanceOf(userA), 700e6);

        factory.withdrawFees(200e6, userB);
        assertEq(rewardToken.balanceOf(userB), 200e6);
        assertEq(rewardToken.balanceOf(address(factory)), 100e6);
    }

    function test_setMyRewardBehavior_revertsWhenUserUnbound() public {
        vm.prank(userA);
        vm.expectRevert(NodeOperatorFactory.NoBoundNodeOperator.selector);
        factory.setMyRewardBehavior(uint8(NodeOperator.RewardBehavior.AutoRestake));
    }

    function test_setMyRewardBehavior_revertsOnTokenMismatch() public {
        address opAddr = factory.addNode(nodeA);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAddr);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        vm.prank(userA);
        vm.expectRevert(NodeOperator.RestakeModeUnsupportedTokenPair.selector);
        factory.setMyRewardBehavior(uint8(NodeOperator.RewardBehavior.AutoRestake));
    }

    function test_claimRewards_restakeModeCompoundsAndTakesRestakeFee() public {
        factory.setRewardToken(address(stakeToken));
        factory.setDefaultModeFeeBps(3000, 1500);
        address opAddr = factory.addNode(nodeA);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAddr);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        vm.prank(userA);
        factory.setMyRewardBehavior(uint8(NodeOperator.RewardBehavior.AutoRestake));

        uint256 feeBefore = stakeToken.balanceOf(address(factory));
        uint256 stakeBefore = stakingOps.stakeOf(nodeA);
        stakeToken.mint(opAddr, 1_000e6);

        vm.prank(userA);
        factory.claimRewards();

        assertEq(stakeToken.balanceOf(address(factory)), feeBefore + 150e6);
        assertEq(stakingOps.stakeOf(nodeA), stakeBefore + 850e6);
        assertEq(stakeToken.balanceOf(userA), 1_000_000e6);
    }

    function test_withdrawUnstaked_resetsOperatorBehaviorToWithdraw() public {
        factory.setRewardToken(address(stakeToken));
        address opAddr = factory.addNode(nodeA);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAddr);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        vm.prank(userA);
        factory.setMyRewardBehavior(uint8(NodeOperator.RewardBehavior.AutoRestake));
        assertEq(
            uint256(NodeOperator(opAddr).rewardBehavior()), uint256(uint8(NodeOperator.RewardBehavior.AutoRestake))
        );

        vm.prank(userA);
        factory.requestUnstake(STAKE_AMOUNT);
        vm.warp(block.timestamp + stakingOps.unstakeDelay() + 1);
        vm.prank(userA);
        factory.withdrawUnstaked();

        assertEq(
            uint256(NodeOperator(opAddr).rewardBehavior()), uint256(uint8(NodeOperator.RewardBehavior.WithdrawToUser))
        );
    }

    function test_setDefaultModeFeeBps_appliesToNewOperatorsOnly() public {
        factory.setDefaultModeFeeBps(1111, 2222);
        address opAAddr = factory.addNode(nodeA);
        assertEq(NodeOperator(opAAddr).withdrawFeeBps(), 1111);
        assertEq(NodeOperator(opAAddr).restakeFeeBps(), 2222);

        factory.setDefaultModeFeeBps(3333, 4444);
        assertEq(NodeOperator(opAAddr).withdrawFeeBps(), 1111);
        assertEq(NodeOperator(opAAddr).restakeFeeBps(), 2222);

        address opBAddr = factory.addNode(nodeB);
        assertEq(NodeOperator(opBAddr).withdrawFeeBps(), 3333);
        assertEq(NodeOperator(opBAddr).restakeFeeBps(), 4444);
    }

    function test_setOperatorModeFeeBps_ownerCanOverridePerOperator() public {
        address opAddr = factory.addNode(nodeA);
        factory.setOperatorModeFeeBps(opAddr, 3100, 1700);

        (uint256 withdrawBps, uint256 restakeBps) = factory.operatorModeFeeBps(opAddr);
        assertEq(withdrawBps, 3100);
        assertEq(restakeBps, 1700);
    }

    function test_withdrawFees_revertsForNonOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xDEAD)));
        factory.withdrawFees(1, userA);
    }

    // ──────────────────────────────────────────────
    // Full lifecycle test
    // ──────────────────────────────────────────────

    function test_setDefaultModeFeeBps_revertsAboveMaxCap() public {
        vm.expectRevert(NodeOperatorFactory.FeeTooHigh.selector);
        factory.setDefaultModeFeeBps(10001, 0);

        vm.expectRevert(NodeOperatorFactory.FeeTooHigh.selector);
        factory.setDefaultModeFeeBps(0, 10001);
    }

    function test_harvestAllRewards_harvestsAllAssignedNodes() public {
        factory.setDefaultModeFeeBps(3000, 1500);
        address opAAddr = factory.addNode(nodeA);
        address opBAddr = factory.addNode(nodeB);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAAddr);
        vm.prank(nodeB);
        stakingOps.approveStaker(opBAddr);

        stakeToken.mint(userA, 2_000_000e6);
        stakeToken.mint(userB, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userB);
        stakeToken.approve(address(factory), type(uint256).max);

        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);
        vm.prank(userB);
        factory.stake(STAKE_AMOUNT);

        address boundOpA = factory.userToOperator(userA);
        address boundOpB = factory.userToOperator(userB);
        rewardToken.mint(boundOpA, 1_000e6);
        rewardToken.mint(boundOpB, 500e6);

        factory.harvestAllRewards();

        // 30% fee on each
        assertEq(rewardToken.balanceOf(userA), 700e6);
        assertEq(rewardToken.balanceOf(userB), 350e6);
        assertEq(rewardToken.balanceOf(address(factory)), 450e6);
    }

    function test_removeNode_swapAndPopWithThreeNodes() public {
        address nodeC = address(0xC001);
        address opAAddr = factory.addNode(nodeA);
        factory.addNode(nodeB);
        address opCAddr = factory.addNode(nodeC);

        assertEq(factory.nodeCount(), 3);

        // Remove first node (triggers swap with last)
        factory.removeNode(nodeA);
        assertEq(factory.nodeCount(), 2);
        assertEq(factory.operatorToNode(opAAddr), address(0));

        // nodeC should have been swapped into nodeA's slot
        assertEq(factory.nodeToOperator(nodeC), opCAddr);
        assertEq(factory.nodeToOperator(nodeB), factory.allNodeOperators()[1]);

        // Remaining nodes should still be functional
        assertEq(factory.nodeToOperator(nodeB) != address(0), true);
        assertEq(factory.nodeToOperator(nodeC) != address(0), true);
    }

    function test_pendingRewards_returnsCorrectAmount() public {
        address opAddr = factory.addNode(nodeA);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAddr);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        // Before any rewards, pending should be 0
        uint256 pending = factory.pendingRewards(userA);
        assertEq(pending, 0);
    }

    function test_fullLifecycle_stakeUnstakeWithdrawRestake() public {
        address opAAddr = factory.addNode(nodeA);
        factory.addNode(nodeB);

        vm.prank(nodeA);
        stakingOps.approveStaker(opAAddr);

        stakeToken.mint(userA, 5_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);

        // Stake — auto-binds to a free node
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);
        address firstOp = factory.userToOperator(userA);
        address firstNode = factory.userToNode(userA);
        assertTrue(firstOp != address(0));

        // Unstake
        vm.prank(userA);
        factory.requestUnstake(STAKE_AMOUNT);

        // Withdraw
        vm.warp(block.timestamp + stakingOps.unstakeDelay() + 1);
        vm.prank(userA);
        factory.withdrawUnstaked();

        // User should be unbound
        assertEq(factory.userToOperator(userA), address(0));
        assertTrue(factory.isFreeNode(firstNode));

        // Re-approve staker for the node that was released
        vm.prank(firstNode);
        stakingOps.approveStaker(firstOp);

        // Re-stake — auto-binds to a free node
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);
        address secondOp = factory.userToOperator(userA);
        assertTrue(secondOp != address(0));
    }
}
