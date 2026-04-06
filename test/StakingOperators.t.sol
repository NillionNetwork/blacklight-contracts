// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockFeeOnTransferERC20.sol";
import "../src/ProtocolConfig.sol";
import "../src/StakingOperators.sol";

contract StakingOperatorsTest is Test {
    MockERC20 stakeToken;
    ProtocolConfig config;
    StakingOperators stakingOps;

    address admin = address(0xA11CE);

    function setUp() public {
        stakeToken = new MockERC20("STAKE", "STK");

        vm.startPrank(admin);
        stakingOps = new StakingOperators(IERC20(address(stakeToken)), admin, 1 days);
        vm.stopPrank();

        config = new ProtocolConfig(
            address(this),
            address(stakingOps),
            address(this),
            address(this),
            address(this),
            2,
            0,
            5,
            0,
            1,
            1,
            10,
            10,
            100,
            1e18
        );

        vm.prank(admin);
        stakingOps.setProtocolConfig(config);
    }

    function test_stakeTo_bindsStaker() public {
        address operator = address(0xB0B);
        address staker1 = address(0x111);
        address staker2 = address(0x222);

        stakeToken.mint(staker1, 2e18);
        stakeToken.mint(staker2, 2e18);

        vm.startPrank(staker1);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 1e18);
        vm.stopPrank();

        vm.startPrank(staker2);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        vm.expectRevert(StakingOperators.DifferentStaker.selector);
        stakingOps.stakeTo(operator, 1e18);
        vm.stopPrank();

        assertEq(stakingOps.operatorStaker(operator), staker1);
        assertEq(stakingOps.stakeOf(operator), 1e18);
    }

    function test_register_requiresMinStake() public {
        address operator = address(0xB0B);
        stakeToken.mint(operator, 2e18);

        vm.startPrank(operator);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 1e18);
        stakingOps.requestUnstake(operator, 0.5e18);
        vm.expectRevert(StakingOperators.InsufficientStakeForActivation.selector);
        stakingOps.registerOperator("ipfs://x");
        stakingOps.stakeTo(operator, 0.5e18);
        stakingOps.registerOperator("ipfs://x");
        vm.stopPrank();

        assertTrue(stakingOps.isActiveOperator(operator));
    }

    function test_stakeTo_requiresMinStakeOnInitialBind() public {
        address operator = address(0xB0B);
        stakeToken.mint(operator, 1e18);

        vm.startPrank(operator);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        vm.expectRevert(StakingOperators.InsufficientStakeForActivation.selector);
        stakingOps.stakeTo(operator, 0.5e18);
        vm.stopPrank();
    }

    function test_stakeTo_allowsTopUpAfterMinIncrease() public {
        address operator = address(0xB0B);
        stakeToken.mint(operator, 3e18);

        vm.startPrank(operator);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 1e18);
        vm.stopPrank();

        config.setParams(
            config.baseCommitteeSize(),
            config.committeeSizeGrowthBps(),
            config.maxCommitteeSize(),
            config.maxEscalations(),
            config.quorumBps(),
            config.verificationBps(),
            config.responseWindow(),
            config.jailDuration(),
            config.maxVoteBatchSize(),
            2e18
        );

        vm.startPrank(operator);
        stakingOps.stakeTo(operator, 0.5e18);
        vm.stopPrank();

        assertEq(stakingOps.stakeOf(operator), 1.5e18);
    }

    function test_fullUnstakeStillClearsBinding() public {
        address operator = address(0xB0B);
        stakeToken.mint(operator, 2e18);

        vm.startPrank(operator);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 1e18);
        stakingOps.requestUnstake(operator, 1e18);
        vm.warp(block.timestamp + 1 days + 1);
        stakingOps.withdrawUnstaked(operator);
        vm.stopPrank();

        assertEq(stakingOps.stakeOf(operator), 0);
        assertEq(stakingOps.operatorStaker(operator), address(0));
    }

    function test_requestUnstake_and_withdraw() public {
        address operator = address(0xB0B);
        stakeToken.mint(operator, 3e18);

        vm.startPrank(operator);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 2e18);
        stakingOps.registerOperator("ipfs://x");

        stakingOps.requestUnstake(operator, 1e18);
        assertEq(stakingOps.stakeOf(operator), 1e18);

        // before delay
        vm.expectRevert(StakingOperators.NotReady.selector);
        stakingOps.withdrawUnstaked(operator);

        vm.warp(block.timestamp + 1 days + 1);
        stakingOps.withdrawUnstaked(operator);
        vm.stopPrank();

        assertEq(stakeToken.balanceOf(operator), 2e18); // 3e18 minted - 2e18 staked + 1e18 withdrawn
    }

    function test_slash_active_and_unbonding() public {
        address operator = address(0xB0B);
        stakeToken.mint(operator, 5e18);

        vm.startPrank(operator);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 3e18);
        stakingOps.registerOperator("ipfs://x");
        stakingOps.requestUnstake(operator, 1e18); // active stake 2e18, 1e18 unbonding
        vm.stopPrank();

        uint256 deadBefore = stakeToken.balanceOf(address(0xdead));

        vm.startPrank(admin);
        stakingOps.grantRole(stakingOps.SLASHER_ROLE(), admin);
        stakingOps.slash(operator, 3e18);
        vm.stopPrank();

        // slashed all active (2e18) + unbonding (1e18)
        assertEq(stakingOps.stakeOf(operator), 0);
        assertEq(stakeToken.balanceOf(address(0xdead)) - deadBefore, 3e18);
    }

    function test_jail_deactivates_and_requires_reactivate() public {
        address operator = address(0xB0B);
        stakeToken.mint(operator, 2e18);

        vm.startPrank(operator);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 1e18);
        stakingOps.registerOperator("ipfs://x");
        vm.stopPrank();

        assertTrue(stakingOps.isActiveOperator(operator));

        vm.startPrank(admin);
        stakingOps.grantRole(stakingOps.SLASHER_ROLE(), admin);
        stakingOps.jail(operator, uint64(block.timestamp + 7 days));
        vm.stopPrank();

        assertTrue(stakingOps.isJailed(operator));
        assertFalse(stakingOps.isActiveOperator(operator));

        vm.warp(block.timestamp + 8 days);

        // still inactive (policy set active=false); must reactivate manually
        assertFalse(stakingOps.isActiveOperator(operator));
        vm.prank(operator);
        stakingOps.reactivateOperator();
        assertTrue(stakingOps.isActiveOperator(operator));
    }

    function test_requestUnstake_revertsWhileJailed() public {
        address operator = address(0xB0B);
        stakeToken.mint(operator, 2e18);

        vm.startPrank(operator);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 1e18);
        stakingOps.registerOperator("ipfs://x");
        vm.stopPrank();

        vm.startPrank(admin);
        stakingOps.grantRole(stakingOps.SLASHER_ROLE(), admin);
        stakingOps.jail(operator, uint64(block.timestamp + 7 days));
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(StakingOperators.OperatorJailed.selector);
        stakingOps.requestUnstake(operator, 1e18);
    }

    function test_snapshot_and_stakeAt_checkpoints() public {
        address operator = address(0xB0B);
        stakeToken.mint(operator, 3e18);

        vm.startPrank(operator);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 2e18);
        vm.stopPrank();

        // set snapshotter
        vm.prank(admin);
        stakingOps.setSnapshotter(address(this));

        vm.roll(2);
        uint64 snap1 = stakingOps.snapshot();
        assertEq(stakingOps.stakeAt(operator, snap1), 2e18);

        vm.startPrank(operator);
        stakingOps.requestUnstake(operator, 1e18); // stake drops to 1e18
        vm.stopPrank();

        vm.roll(4);
        uint64 snap2 = stakingOps.snapshot();
        assertEq(stakingOps.stakeAt(operator, snap2), 1e18);
        assertEq(stakingOps.stakeAt(operator, snap1), 2e18);
    }

    function test_stakeTo_revertsForUnauthorizedStakerWhenApproved() public {
        address operator = address(0xB0B);
        address approved = address(0x111);
        address attacker = address(0x222);

        stakeToken.mint(approved, 1e18);
        stakeToken.mint(attacker, 1e18);

        vm.prank(operator);
        stakingOps.approveStaker(approved);

        vm.startPrank(attacker);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        vm.expectRevert(StakingOperators.UnauthorizedStaker.selector);
        stakingOps.stakeTo(operator, 1e18);
        vm.stopPrank();

        vm.startPrank(approved);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 1e18);
        vm.stopPrank();

        assertEq(stakingOps.operatorStaker(operator), approved);
    }

    function test_registerOperator_revertsWhenActiveSetFull() public {
        vm.prank(admin);
        stakingOps.setMaxActiveOperators(1);

        address operator1 = address(0xB0B1);
        address operator2 = address(0xB0B2);

        stakeToken.mint(operator1, 2e18);
        stakeToken.mint(operator2, 2e18);

        vm.startPrank(operator1);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator1, 1e18);
        stakingOps.registerOperator("ipfs://one");
        vm.stopPrank();

        vm.startPrank(operator2);
        stakeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator2, 1e18);
        vm.expectRevert(StakingOperators.TooManyActiveOperators.selector);
        stakingOps.registerOperator("ipfs://two");
        vm.stopPrank();
    }

    function test_adminSetters_updateValues() public {
        address newSnapshotter = address(0x1234);
        address newHeartbeatManager = address(0x5678);

        vm.prank(admin);
        stakingOps.setUnstakeDelay(2 days);
        assertEq(stakingOps.unstakeDelay(), 2 days);

        vm.prank(admin);
        stakingOps.setMaxActiveOperators(42);
        assertEq(stakingOps.maxActiveOperators(), 42);

        vm.prank(admin);
        stakingOps.setSnapshotter(newSnapshotter);
        assertEq(stakingOps.snapshotter(), newSnapshotter);

        vm.prank(admin);
        stakingOps.setHeartbeatManager(newHeartbeatManager);
        assertEq(stakingOps.heartbeatManager(), newHeartbeatManager);

        ProtocolConfig newConfig = new ProtocolConfig(
            address(this),
            address(stakingOps),
            address(this),
            address(this),
            address(this),
            2,
            0,
            5,
            0,
            1,
            1,
            10,
            10,
            100,
            1e18
        );

        vm.prank(admin);
        stakingOps.setProtocolConfig(newConfig);
        assertEq(address(stakingOps.protocolConfig()), address(newConfig));
    }

    function test_adminSetters_onlyAdmin() public {
        address nonAdmin = address(0xBEEF);

        vm.prank(nonAdmin);
        vm.expectRevert();
        stakingOps.setUnstakeDelay(2 days);

        vm.prank(nonAdmin);
        vm.expectRevert();
        stakingOps.setMaxActiveOperators(10);

        vm.prank(nonAdmin);
        vm.expectRevert();
        stakingOps.setSnapshotter(address(0x1234));

        vm.prank(nonAdmin);
        vm.expectRevert();
        stakingOps.setHeartbeatManager(address(0x5678));
    }

    function test_adminSetters_validateBounds() public {
        vm.prank(admin);
        vm.expectRevert(StakingOperators.InvalidUnstakeDelay.selector);
        stakingOps.setUnstakeDelay(0);

        vm.prank(admin);
        vm.expectRevert(StakingOperators.InvalidUnstakeDelay.selector);
        stakingOps.setUnstakeDelay(15 days);

        vm.prank(admin);
        vm.expectRevert(StakingOperators.InvalidMaxActiveOperators.selector);
        stakingOps.setMaxActiveOperators(0);

        vm.prank(admin);
        vm.expectRevert(StakingOperators.ZeroAddress.selector);
        stakingOps.setSnapshotter(address(0));

        vm.prank(admin);
        vm.expectRevert(StakingOperators.InvalidAddress.selector);
        stakingOps.setHeartbeatManager(address(0));
    }
}

contract StakingOperatorsFeeOnTransferTest is Test {
    MockFeeOnTransferERC20 feeToken;
    ProtocolConfig config;
    StakingOperators stakingOps;

    address admin = address(0xA11CE);
    uint256 constant FEE_BPS = 500; // 5% fee

    function setUp() public {
        feeToken = new MockFeeOnTransferERC20("FEE", "FEE", FEE_BPS);

        vm.startPrank(admin);
        stakingOps = new StakingOperators(IERC20(address(feeToken)), admin, 1 days);
        vm.stopPrank();

        config = new ProtocolConfig(
            address(this),
            address(stakingOps),
            address(this),
            address(this),
            address(this),
            2,
            0,
            5,
            0,
            1,
            1,
            10,
            10,
            100,
            1e18
        );

        vm.prank(admin);
        stakingOps.setProtocolConfig(config);
    }

    function test_stakeTo_feeOnTransfer_accountsActualReceived() public {
        address operator = address(0xB0B);
        uint256 stakeAmount = 2e18;
        uint256 expectedFee = (stakeAmount * FEE_BPS) / 10_000; // 0.1e18
        uint256 expectedStake = stakeAmount - expectedFee; // 1.9e18

        feeToken.mint(operator, stakeAmount);

        vm.startPrank(operator);
        feeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, stakeAmount);
        vm.stopPrank();

        // Accounting matches actual tokens held
        assertEq(stakingOps.stakeOf(operator), expectedStake);
        assertEq(feeToken.balanceOf(address(stakingOps)), expectedStake);
    }

    function test_stakeTo_feeOnTransfer_totalStakedMatchesBalance() public {
        address op1 = address(0xB0B1);
        address op2 = address(0xB0B2);

        feeToken.mint(op1, 2e18);
        feeToken.mint(op2, 2e18);

        vm.startPrank(op1);
        feeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(op1, 2e18);
        vm.stopPrank();

        vm.startPrank(op2);
        feeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(op2, 2e18);
        vm.stopPrank();

        // totalStaked should equal actual contract balance
        assertEq(stakingOps.totalStaked(), feeToken.balanceOf(address(stakingOps)));
    }

    function test_stakeTo_feeOnTransfer_noPhantomBalance() public {
        address operator = address(0xB0B);
        feeToken.mint(operator, 4e18);

        vm.startPrank(operator);
        feeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, 2e18);
        stakingOps.stakeTo(operator, 2e18);
        vm.stopPrank();

        uint256 contractBalance = feeToken.balanceOf(address(stakingOps));
        uint256 recordedStake = stakingOps.stakeOf(operator);

        // No phantom balance: recorded stake must not exceed actual tokens
        assertEq(recordedStake, contractBalance);
        assertLe(recordedStake, contractBalance);
    }

    function test_stakeTo_feeOnTransfer_fullCycleWithdraw() public {
        address operator = address(0xB0B);
        uint256 stakeAmount = 2e18;
        feeToken.mint(operator, stakeAmount);

        vm.startPrank(operator);
        feeToken.approve(address(stakingOps), type(uint256).max);
        stakingOps.stakeTo(operator, stakeAmount);

        uint256 actualStake = stakingOps.stakeOf(operator);

        // Unstake the full recorded amount
        stakingOps.requestUnstake(operator, actualStake);
        vm.warp(block.timestamp + 1 days + 1);

        // Withdraw should not revert — contract holds enough tokens
        stakingOps.withdrawUnstaked(operator);
        vm.stopPrank();

        assertEq(stakingOps.stakeOf(operator), 0);
    }

    function test_stakeTo_feeOnTransfer_eventEmitsActualAmount() public {
        address operator = address(0xB0B);
        uint256 stakeAmount = 2e18;
        uint256 expectedStake = stakeAmount - (stakeAmount * FEE_BPS) / 10_000;

        feeToken.mint(operator, stakeAmount);

        vm.startPrank(operator);
        feeToken.approve(address(stakingOps), type(uint256).max);

        vm.expectEmit(true, true, false, true);
        emit StakingOperators.StakedTo(operator, operator, expectedStake);
        stakingOps.stakeTo(operator, stakeAmount);
        vm.stopPrank();
    }
}
