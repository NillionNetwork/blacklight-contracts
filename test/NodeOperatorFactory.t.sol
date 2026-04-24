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

        // Warp past harvest grace period
        vm.warp(block.timestamp + factory.harvestGracePeriod() + 1);

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
        vm.warp(block.timestamp + factory.harvestGracePeriod() + 1);

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

        // Full unstake switches to WithdrawToUser (NST-5 fix)
        assertEq(
            uint256(NodeOperator(opAddr).rewardBehavior()), uint256(uint8(INodeOperator.RewardBehavior.WithdrawToUser))
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
        // 50% is the max (5000 bps)
        factory.setDefaultModeFeeBps(5000, 5000);

        vm.expectRevert(NodeOperatorFactory.FeeTooHigh.selector);
        factory.setDefaultModeFeeBps(5001, 0);

        vm.expectRevert(NodeOperatorFactory.FeeTooHigh.selector);
        factory.setDefaultModeFeeBps(0, 5001);
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

        // Warp past harvest grace period
        vm.warp(block.timestamp + factory.harvestGracePeriod() + 1);

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

    // ──────────────────────────────────────────────
    // NST-9: Operator ownership migration
    // ──────────────────────────────────────────────

    function test_migrateOperator_transfersOwnership() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);
        address newFactory = address(0xFAC2);

        factory.migrateOperator(opAddr, newFactory);
        assertEq(NodeOperator(opAddr).owner(), newFactory);
    }

    function test_migrateOperator_revertsForNonOwner() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", userA));
        factory.migrateOperator(opAddr, address(0xFAC2));
    }

    function test_migrateOperator_revertsForInvalidOperator() public {
        vm.expectRevert(NodeOperatorFactory.InvalidNodeOperator.selector);
        factory.migrateOperator(address(0xDEAD), address(0xFAC2));
    }

    function test_migrateOperator_revertsForZeroNewOwner() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);
        vm.expectRevert(NodeOperatorFactory.ZeroAddress.selector);
        factory.migrateOperator(opAddr, address(0));
    }

    // ──────────────────────────────────────────────
    // NST-10: Token rescue via factory
    // ──────────────────────────────────────────────

    function test_rescueOperatorTokens_recoversStrandedToken() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);
        MockERC20 oldToken = new MockERC20("OLD", "OLD");
        oldToken.mint(opAddr, 500e6);

        factory.rescueOperatorTokens(opAddr, IERC20(address(oldToken)), address(this), 500e6);
        assertEq(oldToken.balanceOf(address(this)), 500e6);
    }

    function test_rescueOperatorTokens_revertsForActiveToken() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);
        stakeToken.mint(opAddr, 100e6);

        vm.expectRevert(NodeOperator.CannotRescueActiveToken.selector);
        factory.rescueOperatorTokens(opAddr, IERC20(address(stakeToken)), address(this), 100e6);
    }

    function test_rescueOperatorTokens_revertsForInvalidOperator() public {
        vm.expectRevert(NodeOperatorFactory.InvalidNodeOperator.selector);
        factory.rescueOperatorTokens(address(0xDEAD), IERC20(address(0x1)), address(this), 100);
    }

    // ──────────────────────────────────────────────
    // NST-17: Atomic dependency update
    // ──────────────────────────────────────────────

    function test_setDependencies_updatesAllThree() public {
        // Deploy new compatible contracts
        StakingOperators newStaking = new StakingOperators(IERC20(address(stakeToken)), admin, 1 days);
        RewardPolicy newReward = new RewardPolicy(IERC20(address(stakeToken)), address(manager), governance, 1 days, 0);

        factory.setDependencies(address(newStaking), address(newReward), address(stakeToken));

        assertEq(factory.stakingOperators(), address(newStaking));
        assertEq(factory.rewardPolicy(), address(newReward));
        assertEq(factory.token(), address(stakeToken));
    }

    function test_setDependencies_revertsOnTokenMismatch() public {
        MockERC20 otherToken = new MockERC20("OTHER", "OTH");
        RewardPolicy newReward = new RewardPolicy(IERC20(address(otherToken)), address(manager), governance, 1 days, 0);

        vm.expectRevert(NodeOperatorFactory.TokenMismatch.selector);
        factory.setDependencies(address(stakingOps), address(newReward), address(stakeToken));
    }

    function test_setDependencies_revertsOnZeroAddress() public {
        vm.expectRevert(NodeOperatorFactory.ZeroAddress.selector);
        factory.setDependencies(address(0), address(sameTokenRewardPolicy), address(stakeToken));
    }

    // ──────────────────────────────────────────────
    // NST-18: Batch harvest failure observability
    // ──────────────────────────────────────────────

    function test_harvestAllRewards_emitsHarvestFailedOnBrokenOperator() public {
        _approvePredictedStaker(nodeA);
        address opAAddr = factory.addNode(nodeA);
        _approvePredictedStaker(nodeB);
        address opBAddr = factory.addNode(nodeB);

        // Bind userA to opA and stake
        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        // opB has no user assigned → harvestRewards will revert with ZeroAddress
        // Expect a HarvestFailed event (don't check topic values, just that it's emitted)
        vm.expectEmit(false, false, false, false);
        emit NodeOperatorFactory.HarvestFailed(address(0), "");
        factory.harvestAllRewards();
    }

    // ──────────────────────────────────────────────
    // Permissionless harvest grace period
    // ──────────────────────────────────────────────

    function test_harvestGracePeriod_permissionlessHarvestBlockedAfterBehaviorChange() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        // User changes behavior to WithdrawToUser
        vm.prank(userA);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        // Mint rewards to operator
        stakeToken.mint(opAddr, 1_000e6);

        // Permissionless harvest should revert within grace period
        vm.expectRevert(NodeOperatorFactory.HarvestGracePeriodActive.selector);
        factory.harvestRewards(opAddr);
    }

    function test_harvestGracePeriod_userCanStillClaimDuringGracePeriod() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        vm.prank(userA);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        stakeToken.mint(opAddr, 1_000e6);

        // User-initiated claim should still work during grace period
        uint256 balBefore = stakeToken.balanceOf(userA);
        vm.prank(userA);
        factory.claimRewards();
        assertEq(stakeToken.balanceOf(userA) - balBefore, 1_000e6);
    }

    function test_harvestGracePeriod_permissionlessHarvestWorksAfterGracePeriod() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        vm.prank(userA);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        // Warp past grace period
        vm.warp(block.timestamp + factory.harvestGracePeriod() + 1);

        stakeToken.mint(opAddr, 1_000e6);

        // Permissionless harvest should work after grace period
        uint256 balBefore = stakeToken.balanceOf(userA);
        factory.harvestRewards(opAddr);
        assertEq(stakeToken.balanceOf(userA) - balBefore, 1_000e6);
    }

    function test_harvestGracePeriod_batchHarvestSkipsDuringGracePeriod() public {
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

        // Both users change behavior — both operators enter grace period
        vm.prank(userA);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);
        vm.prank(userB);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        // Use actual bound operators (LIFO binding means order may differ from addNode)
        address opAAddr = factory.userToOperator(userA);
        address opBAddr = factory.userToOperator(userB);
        stakeToken.mint(opAAddr, 1_000e6);
        stakeToken.mint(opBAddr, 500e6);

        // Batch harvest should skip both (grace period active) without reverting
        factory.harvestAllRewards();

        // Rewards should still be sitting on the operators (not harvested)
        assertEq(stakeToken.balanceOf(opAAddr), 1_000e6);
        assertEq(stakeToken.balanceOf(opBAddr), 500e6);
    }

    function test_setHarvestGracePeriod_ownerCanUpdate() public {
        factory.setHarvestGracePeriod(30);
        assertEq(factory.harvestGracePeriod(), 30);
    }

    function test_setHarvestGracePeriod_revertsAboveMax() public {
        uint256 max = factory.MAX_HARVEST_GRACE_PERIOD();
        vm.expectRevert(NodeOperatorFactory.GracePeriodTooLong.selector);
        factory.setHarvestGracePeriod(max + 1);
    }

    function test_setHarvestGracePeriod_revertsForNonOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xDEAD)));
        factory.setHarvestGracePeriod(30);
    }

    function test_setHarvestGracePeriod_zeroDisablesGracePeriod() public {
        _approvePredictedStaker(nodeA);
        address opAddr = factory.addNode(nodeA);

        stakeToken.mint(userA, 2_000_000e6);
        vm.prank(userA);
        stakeToken.approve(address(factory), type(uint256).max);
        vm.prank(userA);
        factory.stake(STAKE_AMOUNT);

        vm.prank(userA);
        factory.setMyRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        // Disable grace period
        factory.setHarvestGracePeriod(0);

        stakeToken.mint(opAddr, 1_000e6);

        // Permissionless harvest works immediately
        uint256 balBefore = stakeToken.balanceOf(userA);
        factory.harvestRewards(opAddr);
        assertEq(stakeToken.balanceOf(userA) - balBefore, 1_000e6);
    }

    // ──────────────────────────────────────────────
    // S3: renounceOwnership disabled
    // ──────────────────────────────────────────────

    function test_renounceOwnership_reverts() public {
        vm.expectRevert("disabled");
        factory.renounceOwnership();
    }
}
