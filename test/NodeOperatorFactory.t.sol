// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../src/NodeOperatorFactory.sol";
import "../src/NodeOperator.sol";
import "../src/RewardPolicy.sol";
import "./helpers/BlacklightFixture.sol";

contract NodeOperatorFactoryTest is BlacklightFixture {
    NodeOperatorFactory internal factory;
    RewardPolicy internal sameTokenRewardPolicy;

    address internal userA = address(0x1111);
    address internal userB = address(0x2222);
    address internal nodeA = address(0xA001);
    address internal nodeB = address(0xB001);

    uint256 constant STAKE_AMOUNT = 1_000_000e6;

    function _approvePredictedStaker(address node) internal returns (address predicted) {
        predicted = factory.predictNodeOperatorAddress(node);
        vm.prank(node);
        stakingOps.approveStaker(predicted);
    }

    function setUp() public {
        uint256[] memory stakes = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            stakes[i] = 100e18;
        }
        _deploySystem(5, stakes, 5, 100, 6700, 6700, 5 minutes, 2 minutes, 0);
        config.setParams(5, 0, 100, 0, 6700, 6700, 5 minutes, 2 minutes, 100, 1e6);

        // Deploy a reward policy that uses stakeToken (same token for staking & rewards)
        sameTokenRewardPolicy = new RewardPolicy(IERC20(address(stakeToken)), address(manager), governance, 1 days, 0);
        config.setModules(
            address(stakingOps), address(selector), address(jailingPolicy), address(sameTokenRewardPolicy)
        );

        factory = new NodeOperatorFactory(
            address(this), address(stakingOps), address(sameTokenRewardPolicy), address(stakeToken), STAKE_AMOUNT
        );
        factory.setDefaultModeFeeBps(0, 0);
    }

    // ──────────────────────────────────────────────
    // addNode tests
    // ──────────────────────────────────────────────

    function test_addNode_deploysAndConfiguresNodeOperator() public {
        address predicted = _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);

        assertEq(opAddr, predicted);
        NodeOperator op = NodeOperator(opAddr);
        assertEq(op.owner(), address(factory));
        assertEq(op.nodeAddress(), nodeA);
        assertEq(address(op.stakingOperators()), address(stakingOps));
        assertEq(address(op.rewardPolicy()), address(sameTokenRewardPolicy));
        assertEq(address(op.token()), address(stakeToken));
        assertEq(op.minStake(), STAKE_AMOUNT);
        assertEq(op.withdrawFeeBps(), 0);
        assertEq(op.restakeFeeBps(), 0);
        assertEq(uint256(op.rewardBehavior()), uint256(uint8(INodeOperator.RewardBehavior.AutoRestake)));

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
        _approvePredictedStaker(nodeA);
        factory.addNode(nodeA);
        vm.expectRevert(NodeOperatorFactory.NodeAlreadyRegistered.selector);
        factory.addNode(nodeA);
    }

    function test_addNode_revertsWhenPredictedStakerNotApproved() public {
        vm.expectRevert(NodeOperatorFactory.StakerNotPreapproved.selector);
        factory.addNode(nodeA);
    }

    function test_addNode_revertsWhenWrongStakerApproved() public {
        vm.prank(nodeA);
        stakingOps.approveStaker(address(0xBEEF));

        vm.expectRevert(NodeOperatorFactory.StakerNotPreapproved.selector);
        factory.addNode(nodeA);
    }

    // ──────────────────────────────────────────────
    // stake auto-binding tests
    // ──────────────────────────────────────────────

    function test_stake_autoBindsUserToFreeNode() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);

        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        assertEq(factory.userToOperator(userA), opAddr);
        assertEq(factory.userToNode(userA), nodeA);
        assertEq(factory.nodeToUser(nodeA), userA);
    }

    function test_stake_secondUserBindsToDifferentNode() public {
        _approvePredictedStaker(nodeA);
        _approvePredictedStaker(nodeB);
        factory.addNode(nodeA);
        factory.addNode(nodeB);

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
        _approvePredictedStaker(nodeA);
        factory.addNode(nodeA);

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
        _approvePredictedStaker(nodeA);
        _approvePredictedStaker(nodeB);
        factory.addNode(nodeA);
        factory.addNode(nodeB);

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

        // Default is AutoRestake, switch to WithdrawToUser for this test
        vm.prank(userA);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);
        vm.prank(userB);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        // Mint reward tokens to each user's bound operator
        address boundOpA = factory.userToOperator(userA);
        address boundOpB = factory.userToOperator(userB);
        uint256 rewardA = 700e6;
        uint256 rewardB = 300e6;
        stakeToken.mint(boundOpA, rewardA);
        stakeToken.mint(boundOpB, rewardB);

        uint256 balABefore = stakeToken.balanceOf(userA);
        uint256 balBBefore = stakeToken.balanceOf(userB);

        // Harvest distributes rewards from operator to nodeUser
        factory.harvestRewards(boundOpA);
        factory.harvestRewards(boundOpB);

        assertEq(stakeToken.balanceOf(userA) - balABefore, rewardA);
        assertEq(stakeToken.balanceOf(userB) - balBBefore, rewardB);
    }

    function test_withdrawFees_ownerCanWithdrawHarvestedFees() public {
        factory.setDefaultModeFeeBps(3000, 1500);
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        // Switch to WithdrawToUser so fees go to factory and net to user
        vm.prank(userA);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        uint256 factoryBalBefore = stakeToken.balanceOf(address(factory));
        uint256 userABalBefore = stakeToken.balanceOf(userA);

        stakeToken.mint(opAddr, 1_000e6);
        factory.harvestRewards(opAddr);

        assertEq(stakeToken.balanceOf(address(factory)) - factoryBalBefore, 300e6);
        assertEq(stakeToken.balanceOf(userA) - userABalBefore, 700e6);

        factory.withdrawFees(200e6, userB);
        assertEq(stakeToken.balanceOf(userB), 200e6);
        assertEq(stakeToken.balanceOf(address(factory)) - factoryBalBefore, 100e6);
    }

    function test_setMyRewardBehavior_revertsWhenUserUnbound() public {
        vm.prank(userA);
        vm.expectRevert(NodeOperatorFactory.NoBoundNodeOperator.selector);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.AutoRestake);
    }

    function test_claimRewards_restakeModeCompoundsAndTakesRestakeFee() public {
        factory.setDefaultModeFeeBps(3000, 1500);
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        uint256 feeBefore = stakeToken.balanceOf(address(factory));
        uint256 stakeBefore = stakingOps.stakeOf(nodeA);
        stakeToken.mint(opAddr, 1_000e6);

        vm.prank(userA);
        factory.claimRewards();

        assertEq(stakeToken.balanceOf(address(factory)), feeBefore + 150e6);
        assertEq(stakingOps.stakeOf(nodeA), stakeBefore + 850e6);
        assertEq(stakeToken.balanceOf(userA), 1_000_000e6);
    }

    function test_withdrawUnstaked_preservesRewardBehavior() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        // Default is already AutoRestake
        assertEq(
            uint256(NodeOperator(opAddr).rewardBehavior()), uint256(uint8(INodeOperator.RewardBehavior.AutoRestake))
        );

        vm.prank(userA);
        factory.requestUnstake(STAKE_AMOUNT);
        vm.warp(block.timestamp + stakingOps.unstakeDelay() + 1);
        vm.prank(userA);
        factory.withdrawUnstaked();

        // Behavior is preserved (no reset on withdrawal)
        assertEq(
            uint256(NodeOperator(opAddr).rewardBehavior()), uint256(uint8(INodeOperator.RewardBehavior.AutoRestake))
        );
    }

    function test_setDefaultModeFeeBps_appliesToNewOperatorsOnly() public {
        factory.setDefaultModeFeeBps(1111, 2222);
        _approvePredictedStaker(nodeA);
        address opAAddr = factory.addNode(nodeA);
        assertEq(NodeOperator(opAAddr).withdrawFeeBps(), 1111);
        assertEq(NodeOperator(opAAddr).restakeFeeBps(), 2222);

        factory.setDefaultModeFeeBps(3333, 4444);
        assertEq(NodeOperator(opAAddr).withdrawFeeBps(), 1111);
        assertEq(NodeOperator(opAAddr).restakeFeeBps(), 2222);

        _approvePredictedStaker(nodeB);
        address opBAddr = factory.addNode(nodeB);
        assertEq(NodeOperator(opBAddr).withdrawFeeBps(), 3333);
        assertEq(NodeOperator(opBAddr).restakeFeeBps(), 4444);
    }

    function test_setOperatorModeFeeBps_ownerCanOverridePerOperator() public {
        _approvePredictedStaker(nodeA);
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
        _approvePredictedStaker(nodeA);
        _approvePredictedStaker(nodeB);
        factory.addNode(nodeA);
        factory.addNode(nodeB);

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

        // Switch to WithdrawToUser for this test
        vm.prank(userA);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);
        vm.prank(userB);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        address boundOpA = factory.userToOperator(userA);
        address boundOpB = factory.userToOperator(userB);
        uint256 balABefore = stakeToken.balanceOf(userA);
        uint256 balBBefore = stakeToken.balanceOf(userB);
        uint256 factoryBalBefore = stakeToken.balanceOf(address(factory));

        stakeToken.mint(boundOpA, 1_000e6);
        stakeToken.mint(boundOpB, 500e6);

        factory.harvestAllRewards();

        // 30% fee on each
        assertEq(stakeToken.balanceOf(userA) - balABefore, 700e6);
        assertEq(stakeToken.balanceOf(userB) - balBBefore, 350e6);
        assertEq(stakeToken.balanceOf(address(factory)) - factoryBalBefore, 450e6);
    }

    function test_pendingRewards_returnsCorrectAmount() public {
        _approvePredictedStaker(nodeA);
        factory.addNode(nodeA);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        // Before any rewards, pending should be 0
        uint256 pending = factory.pendingRewards(userA);
        assertEq(pending, 0);
    }

    function test_fullLifecycle_stakeUnstakeWithdraw() public {
        _approvePredictedStaker(nodeA);
        factory.addNode(nodeA);

        stakeToken.mint(userA, 5_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);

        // Stake — auto-binds to a free node
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);
        address firstOp = factory.userToOperator(userA);
        assertTrue(firstOp != address(0));

        // Unstake
        vm.prank(userA);
        factory.requestUnstake(STAKE_AMOUNT);

        // Withdraw
        vm.warp(block.timestamp + stakingOps.unstakeDelay() + 1);
        vm.prank(userA);
        factory.withdrawUnstaked();

        // User stays bound to the same operator (no recycling)
        assertEq(factory.userToOperator(userA), firstOp);
        assertEq(factory.userToNode(userA), nodeA);
        assertEq(stakeToken.balanceOf(userA), 5_000_000e6);
    }
}
