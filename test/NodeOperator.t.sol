// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../src/NodeOperator.sol";
import "../src/RewardPolicy.sol";
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

        // Deploy a reward policy that uses stakeToken (same token for staking & rewards)
        RewardPolicy sameTokenRewardPolicy =
            new RewardPolicy(IERC20(address(stakeToken)), address(manager), governance, 1 days, 0);
        config.setModules(address(stakingOps), address(selector), address(jailingPolicy), address(sameTokenRewardPolicy));

        nodeOp = new NodeOperator(
            address(this),
            STAKE_AMOUNT,
            node1,
            address(stakingOps),
            address(sameTokenRewardPolicy),
            address(stakeToken),
            0, // withdrawFeeBps
            0  // restakeFeeBps
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
        assertEq(nodeOp.nodeUser(), user1);
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

        // Mint tokens directly to nodeOp since _harvestIfPossible
        // distributes the token balance
        stakeToken.mint(address(nodeOp), 1_000e6);
        nodeOp.harvestRewards();

        // Default behavior is AutoRestake, so rewards are compounded into stake
        assertEq(stakingOps.stakeOf(node1), STAKE_AMOUNT + 1_000e6);
    }

    function test_rewardsHarvest_forwardsFeesImmediatelyAndOnlyOnNewRewards() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);
        nodeOp.setModeFeeBps(3000, 1500);
        nodeOp.setRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        stakeToken.mint(address(nodeOp), 1_000e6);
        nodeOp.harvestRewards();

        assertEq(stakeToken.balanceOf(user1), 700e6);
        assertEq(stakeToken.balanceOf(address(this)), 20_000_000e6 - STAKE_AMOUNT + 300e6);
        assertEq(stakeToken.balanceOf(address(nodeOp)), 0);

        // New rewards are fee-charged in isolation; no stale fee balance remains in operator.
        stakeToken.mint(address(nodeOp), 300e6);
        nodeOp.harvestRewards();

        assertEq(stakeToken.balanceOf(user1), 910e6); // +210
        assertEq(stakeToken.balanceOf(address(this)), 20_000_000e6 - STAKE_AMOUNT + 390e6); // +90
        assertEq(stakeToken.balanceOf(address(nodeOp)), 0);
    }

    function test_rewardsHarvest_restakeModeUsesRestakeFeeAndCompoundsStake() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        nodeOp.setModeFeeBps(3000, 1500);

        uint256 stakeBefore = stakingOps.stakeOf(node1);
        uint256 feeReceiverBefore = stakeToken.balanceOf(address(this));

        stakeToken.mint(address(nodeOp), 1_000e6);
        nodeOp.harvestRewards();

        assertEq(stakingOps.stakeOf(node1), stakeBefore + 850e6);
        assertEq(stakeToken.balanceOf(address(this)), feeReceiverBefore + 150e6);
        assertEq(stakeToken.balanceOf(user1), 0);
    }

    function test_defaultRewardBehavior_isAutoRestake() public view {
        assertEq(
            uint256(nodeOp.rewardBehavior()), uint256(uint8(INodeOperator.RewardBehavior.AutoRestake))
        );
    }


    function test_setModeFeeBps_setsModeFees() public {
        nodeOp.setModeFeeBps(1200, 800);
        assertEq(nodeOp.withdrawFeeBps(), 1200);
        assertEq(nodeOp.restakeFeeBps(), 800);
    }

    function test_partialUnstake_revertsWhenRemainderBelowMinStake() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        // Unstaking almost everything reverts — remainder would be below minStake
        uint256 partialAmount = STAKE_AMOUNT - 1;
        vm.expectRevert(NodeOperator.BelowMinimumStake.selector);
        nodeOp.requestUnstake(partialAmount);
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
        // 50% is the max (5000 bps)
        nodeOp.setModeFeeBps(5000, 5000);
        assertEq(nodeOp.withdrawFeeBps(), 5000);
        assertEq(nodeOp.restakeFeeBps(), 5000);

        // 50% + 1 bps reverts
        vm.expectRevert(NodeOperator.FeeTooHigh.selector);
        nodeOp.setModeFeeBps(5001, 0);

        vm.expectRevert(NodeOperator.FeeTooHigh.selector);
        nodeOp.setModeFeeBps(0, 5001);
    }

    function test_constructorRevertsIfFeeAboveCap() public {
        vm.expectRevert(NodeOperator.FeeTooHigh.selector);
        new NodeOperator(
            address(this), STAKE_AMOUNT, node1,
            address(stakingOps), address(0), address(stakeToken),
            5001, 0
        );

        vm.expectRevert(NodeOperator.FeeTooHigh.selector);
        new NodeOperator(
            address(this), STAKE_AMOUNT, node1,
            address(stakingOps), address(0), address(stakeToken),
            0, 5001
        );
    }

    function test_harvestAtMaxFee_userGetsHalf() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);
        nodeOp.setModeFeeBps(5000, 0); // 50% withdraw fee
        nodeOp.setRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);

        stakeToken.mint(address(nodeOp), 1_000e6);
        uint256 ownerBefore = stakeToken.balanceOf(address(this));
        nodeOp.harvestRewards();

        assertEq(stakeToken.balanceOf(user1), 500e6);
        assertEq(stakeToken.balanceOf(address(this)) - ownerBefore, 500e6);
    }

    // ──────────────────────────────────────────────
    // NST-5: Auto-restake on fully-exiting operator
    // ──────────────────────────────────────────────

    function test_fullUnstake_switchesRewardBehaviorToWithdraw() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        // Default is AutoRestake
        assertEq(uint256(nodeOp.rewardBehavior()), uint256(uint8(INodeOperator.RewardBehavior.AutoRestake)));

        // Full unstake should flip to WithdrawToUser
        nodeOp.requestUnstake(STAKE_AMOUNT);
        assertEq(uint256(nodeOp.rewardBehavior()), uint256(uint8(INodeOperator.RewardBehavior.WithdrawToUser)));
    }

    function test_partialUnstake_doesNotChangeRewardBehavior() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT * 3);

        nodeOp.requestUnstake(STAKE_AMOUNT);

        // Partial unstake should keep AutoRestake
        assertEq(uint256(nodeOp.rewardBehavior()), uint256(uint8(INodeOperator.RewardBehavior.AutoRestake)));
    }

    function test_fullUnstake_harvestSendsRewardsToUser() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);

        // Full unstake
        nodeOp.requestUnstake(STAKE_AMOUNT);

        // Simulate pending rewards arriving after exit
        stakeToken.mint(address(nodeOp), 1_000e6);
        nodeOp.harvestRewards();

        // Rewards should go to user, not be restaked
        assertEq(stakeToken.balanceOf(user1), 1_000e6);
        assertEq(stakingOps.stakeOf(node1), 0);
    }

    function test_setRewardBehavior_revertsAutoRestakeWhenStakeZero() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);
        nodeOp.requestUnstake(STAKE_AMOUNT);

        // Behavior was flipped to WithdrawToUser; trying to set AutoRestake should revert
        vm.expectRevert(NodeOperator.BelowMinimumStake.selector);
        nodeOp.setRewardBehavior(INodeOperator.RewardBehavior.AutoRestake);
    }

    function test_setRewardBehavior_allowsWithdrawWhenStakeZero() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);
        nodeOp.requestUnstake(STAKE_AMOUNT);

        // Setting WithdrawToUser when stake is 0 should be allowed
        nodeOp.setRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);
        assertEq(uint256(nodeOp.rewardBehavior()), uint256(uint8(INodeOperator.RewardBehavior.WithdrawToUser)));
    }

    // ──────────────────────────────────────────────
    // NST-7: Token migration rescue
    // ──────────────────────────────────────────────

    function test_rescueTokens_recoversStrandedToken() public {
        MockERC20 oldToken = new MockERC20("OLD", "OLD");
        oldToken.mint(address(nodeOp), 500e6);

        nodeOp.rescueTokens(IERC20(address(oldToken)), address(this), 500e6);
        assertEq(oldToken.balanceOf(address(this)), 500e6);
        assertEq(oldToken.balanceOf(address(nodeOp)), 0);
    }

    function test_rescueTokens_revertsForActiveToken() public {
        stakeToken.mint(address(nodeOp), 100e6);

        vm.expectRevert(NodeOperator.CannotRescueActiveToken.selector);
        nodeOp.rescueTokens(IERC20(address(stakeToken)), address(this), 100e6);
    }

    function test_rescueTokens_revertsForZeroAddress() public {
        MockERC20 oldToken = new MockERC20("OLD", "OLD");
        oldToken.mint(address(nodeOp), 100e6);

        vm.expectRevert(NodeOperator.ZeroAddress.selector);
        nodeOp.rescueTokens(IERC20(address(oldToken)), address(0), 100e6);
    }

    function test_rescueTokens_revertsForZeroAmount() public {
        MockERC20 oldToken = new MockERC20("OLD", "OLD");

        vm.expectRevert(NodeOperator.ZeroAmount.selector);
        nodeOp.rescueTokens(IERC20(address(oldToken)), address(this), 0);
    }

    function test_rescueTokens_revertsForNonOwner() public {
        MockERC20 oldToken = new MockERC20("OLD", "OLD");
        oldToken.mint(address(nodeOp), 100e6);

        address outsider = address(0xDEAD);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        nodeOp.rescueTokens(IERC20(address(oldToken)), outsider, 100e6);
    }

    function test_rescueTokens_partialRescue() public {
        MockERC20 oldToken = new MockERC20("OLD", "OLD");
        oldToken.mint(address(nodeOp), 500e6);

        nodeOp.rescueTokens(IERC20(address(oldToken)), address(this), 200e6);
        assertEq(oldToken.balanceOf(address(nodeOp)), 300e6);
        assertEq(oldToken.balanceOf(address(this)), 200e6);
    }

    // ──────────────────────────────────────────────
    // NST-11: Jailed node stake prevention
    // ──────────────────────────────────────────────

    function _jailNode() internal {
        vm.startPrank(admin);
        stakingOps.grantRole(stakingOps.SLASHER_ROLE(), admin);
        stakingOps.jail(node1, uint64(block.timestamp + 7 days));
        vm.stopPrank();
    }

    function test_stake_revertsWhenNodeJailed() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);
        _jailNode();

        stakeToken.transfer(address(nodeOp), STAKE_AMOUNT);
        vm.expectRevert(NodeOperator.NodeJailed.selector);
        nodeOp.stake();
    }

    function test_harvest_sendsToUserWhenNodeJailedAndAutoRestake() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);
        _jailNode();

        // Simulate rewards arriving while jailed
        stakeToken.mint(address(nodeOp), 1_000e6);
        nodeOp.harvestRewards();

        // Should go to user, not restaked
        assertEq(stakeToken.balanceOf(user1), 1_000e6);
        // Stake unchanged
        assertEq(stakingOps.stakeOf(node1), STAKE_AMOUNT);
    }

    function test_harvest_withdrawModeUnaffectedByJail() public {
        nodeOp.assignUser(user1);
        _stakeViaFactory(STAKE_AMOUNT);
        nodeOp.setRewardBehavior(INodeOperator.RewardBehavior.WithdrawToUser);
        _jailNode();

        stakeToken.mint(address(nodeOp), 1_000e6);
        nodeOp.harvestRewards();

        // WithdrawToUser mode works regardless of jail
        assertEq(stakeToken.balanceOf(user1), 1_000e6);
    }

    function test_harvestRevertsIfRewardModulesUnset() public {
        NodeOperator fresh = new NodeOperator(
            address(this),
            STAKE_AMOUNT,
            node1,
            address(stakingOps),
            address(0), // no rewardPolicy
            address(stakeToken),
            0,
            0
        );
        vm.expectRevert(NodeOperator.ContractNotConfigured.selector);
        fresh.harvestRewards();
    }
}
