// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockL1StandardBridge.sol";
import "../src/EmissionsController.sol";

contract EmissionsControllerTest is Test {
    MockERC20 token;
    MockL1StandardBridge bridge;
    EmissionsController controller;

    address owner = address(this);
    address l2Token = address(0xBEEF);
    address l2Recipient = address(0xCAFE);
    address sinkAddr = address(0xF00D);

    function setUp() public {
        token = new MockERC20("REWARD", "RWD");
        bridge = new MockL1StandardBridge();

        uint256[] memory schedule = new uint256[](2);
        schedule[0] = 100;
        schedule[1] = 150;

        EmissionsController.Recipient memory sink = EmissionsController.Recipient({addr: sinkAddr, bps: 0, isL2: false});

        EmissionsController.Recipient[] memory initial = new EmissionsController.Recipient[](1);
        initial[0] = EmissionsController.Recipient({addr: l2Recipient, bps: 10_000, isL2: true});

        controller = new EmissionsController(
            IERC20Mintable(address(token)),
            IL1StandardBridge(address(bridge)),
            l2Token,
            sink,
            initial,
            block.timestamp + 5,
            10, // epochDuration
            200_000, // l2GasLimit
            300, // global cap
            schedule,
            owner
        );
    }

    // -----------------------------------------------------------------------
    // Legacy semantics preserved under a single 100% L2 recipient
    // -----------------------------------------------------------------------

    function test_mintAndBridge_enforcesEpochTiming() public {
        uint256 readyAt0 = controller.nextEpochReadyAt();
        vm.expectRevert(abi.encodeWithSelector(EmissionsController.EpochNotElapsed.selector, block.timestamp, readyAt0));
        controller.mintAndBridgeNextEpoch();

        vm.warp(readyAt0);
        (uint256 epoch1, uint256 amount1) = controller.mintAndBridgeNextEpoch();
        assertEq(epoch1, 1);
        assertEq(amount1, 100);

        assertEq(token.balanceOf(address(bridge)), 100);
        assertEq(controller.mintedEpochs(), 1);
        assertEq(controller.mintedTotal(), 100);

        uint256 readyAt1 = controller.nextEpochReadyAt();
        vm.expectRevert(abi.encodeWithSelector(EmissionsController.EpochNotElapsed.selector, block.timestamp, readyAt1));
        controller.mintAndBridgeNextEpoch();

        vm.warp(readyAt1);
        (uint256 epoch2, uint256 amount2) = controller.mintAndBridgeNextEpoch();
        assertEq(epoch2, 2);
        assertEq(amount2, 150);

        assertEq(token.balanceOf(address(bridge)), 250);
        assertEq(controller.mintedEpochs(), 2);
        assertEq(controller.mintedTotal(), 250);

        vm.expectRevert(EmissionsController.NoRemainingEpochs.selector);
        controller.mintAndBridgeNextEpoch();
    }

    function test_mintAndBridge_isPermissionless() public {
        address caller = address(0x1234);
        vm.warp(controller.nextEpochReadyAt());

        vm.prank(caller);
        controller.mintAndBridgeNextEpoch();

        assertEq(controller.mintedEpochs(), 1);
        assertEq(token.balanceOf(address(bridge)), 100);
    }

    function test_globalCapExceeded_reverts() public {
        uint256[] memory schedule = new uint256[](2);
        schedule[0] = 200;
        schedule[1] = 150;

        EmissionsController.Recipient memory sink = EmissionsController.Recipient({addr: sinkAddr, bps: 0, isL2: false});
        EmissionsController.Recipient[] memory initial = new EmissionsController.Recipient[](1);
        initial[0] = EmissionsController.Recipient({addr: l2Recipient, bps: 10_000, isL2: true});

        EmissionsController c2 = new EmissionsController(
            IERC20Mintable(address(token)),
            IL1StandardBridge(address(bridge)),
            l2Token,
            sink,
            initial,
            block.timestamp,
            10,
            200_000,
            300,
            schedule,
            owner
        );

        c2.mintAndBridgeNextEpoch();

        vm.warp(block.timestamp + 10);
        vm.expectRevert(
            abi.encodeWithSelector(EmissionsController.GlobalCapExceeded.selector, uint256(150), uint256(100))
        );
        c2.mintAndBridgeNextEpoch();
    }

    function test_emissionForEpoch_bounds() public {
        assertEq(controller.epochs(), 2);
        assertEq(controller.emissionForEpoch(1), 100);
        assertEq(controller.emissionForEpoch(2), 150);

        vm.expectRevert(abi.encodeWithSelector(EmissionsController.InvalidEpoch.selector, uint256(0)));
        controller.emissionForEpoch(0);

        vm.expectRevert(abi.encodeWithSelector(EmissionsController.InvalidEpoch.selector, uint256(3)));
        controller.emissionForEpoch(3);
    }

    function test_setL2GasLimit_onlyOwner() public {
        address nonOwner = address(0xBEEF);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        controller.setL2GasLimit(123);

        controller.setL2GasLimit(123);
        assertEq(controller.l2GasLimit(), 123);
    }

    function test_ensureBridgeApproval_restoresMaxAllowance() public {
        vm.prank(address(controller));
        token.approve(address(bridge), 0);
        assertEq(token.allowance(address(controller), address(bridge)), 0);

        controller.ensureBridgeApproval();
        assertEq(token.allowance(address(controller), address(bridge)), type(uint256).max);
    }

    function test_mintAndBridgeNextEpoch_forwardsEtherToSingleL2Payout() public {
        vm.deal(address(this), 1);
        bridge.setRequiredValue(1);

        vm.warp(controller.nextEpochReadyAt());
        controller.mintAndBridgeNextEpoch{value: 1}();

        assertEq(address(bridge).balance, 1);
        assertEq(bridge.depositCount(), 1);
        assertEq(bridge.depositedValueAt(0), 1);
    }

    // -----------------------------------------------------------------------
    // Constructor initialization
    // -----------------------------------------------------------------------

    function test_constructor_initializesRecipientsAndSink() public view {
        assertEq(controller.recipientCount(), 1);
        EmissionsController.Recipient memory r0 = controller.recipientAt(0);
        assertEq(r0.addr, l2Recipient);
        assertEq(uint256(r0.bps), 10_000);
        assertTrue(r0.isL2);
        assertEq(controller.totalBps(), 10_000);
        assertTrue(controller.isRecipient(l2Recipient));

        (address sAddr, uint16 sBps, bool sIsL2) = controller.remainderSink();
        assertEq(sAddr, sinkAddr);
        assertEq(uint256(sBps), 0);
        assertFalse(sIsL2);
    }

    function test_constructor_revertsOnSumOverflow() public {
        uint256[] memory schedule = new uint256[](1);
        schedule[0] = 1;

        EmissionsController.Recipient memory sink = EmissionsController.Recipient({addr: sinkAddr, bps: 0, isL2: false});
        EmissionsController.Recipient[] memory initial = new EmissionsController.Recipient[](2);
        initial[0] = EmissionsController.Recipient({addr: address(0xAAA1), bps: 8_000, isL2: false});
        initial[1] = EmissionsController.Recipient({addr: address(0xAAA2), bps: 3_000, isL2: false});

        vm.expectRevert(
            abi.encodeWithSelector(EmissionsController.BpsOverflow.selector, uint256(11_000), uint256(10_000))
        );
        new EmissionsController(
            IERC20Mintable(address(token)),
            IL1StandardBridge(address(bridge)),
            l2Token,
            sink,
            initial,
            block.timestamp,
            10,
            200_000,
            0,
            schedule,
            owner
        );
    }

    function test_constructor_revertsOnZeroSink() public {
        uint256[] memory schedule = new uint256[](1);
        schedule[0] = 1;

        EmissionsController.Recipient memory sink =
            EmissionsController.Recipient({addr: address(0), bps: 0, isL2: false});
        EmissionsController.Recipient[] memory initial = new EmissionsController.Recipient[](0);

        vm.expectRevert(EmissionsController.ZeroAddress.selector);
        new EmissionsController(
            IERC20Mintable(address(token)),
            IL1StandardBridge(address(bridge)),
            l2Token,
            sink,
            initial,
            block.timestamp,
            10,
            200_000,
            0,
            schedule,
            owner
        );
    }

    // -----------------------------------------------------------------------
    // Recipient registry mutators
    // -----------------------------------------------------------------------

    function test_addRecipient_onlyOwner() public {
        address nonOwner = address(0xBEEF);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        controller.addRecipient(address(0xAAA1), 1, false);
    }

    function test_addRecipient_rejectsDuplicates() public {
        vm.expectRevert(abi.encodeWithSelector(EmissionsController.RecipientExists.selector, l2Recipient));
        controller.addRecipient(l2Recipient, 1, true);
    }

    function test_addRecipient_rejectsZeroBps() public {
        vm.expectRevert(abi.encodeWithSelector(EmissionsController.InvalidBps.selector, uint256(0)));
        controller.addRecipient(address(0xAAA1), 0, false);
    }

    function test_addRecipient_rejectsZeroAddress() public {
        vm.expectRevert(EmissionsController.ZeroAddress.selector);
        controller.addRecipient(address(0), 1, false);
    }

    function test_addRecipient_enforcesBpsSum() public {
        controller.setRecipientBps(l2Recipient, 9_500);
        vm.expectRevert(
            abi.encodeWithSelector(EmissionsController.BpsOverflow.selector, uint256(10_001), uint256(10_000))
        );
        controller.addRecipient(address(0xAAA1), 501, false);
    }

    function test_addRecipient_enforcesMaxRecipients() public {
        controller.removeRecipient(l2Recipient);

        for (uint256 i = 0; i < 32; i++) {
            controller.addRecipient(address(uint160(0x100 + i)), 1, false);
        }
        assertEq(controller.recipientCount(), 32);

        vm.expectRevert(abi.encodeWithSelector(EmissionsController.TooManyRecipients.selector, uint256(32)));
        controller.addRecipient(address(0xABCD), 1, false);
    }

    function test_removeRecipient_swapsAndPops() public {
        address a = address(0xAAA1);
        address b = address(0xAAA2);
        controller.setRecipientBps(l2Recipient, 1);
        controller.addRecipient(a, 100, false);
        controller.addRecipient(b, 200, false);
        assertEq(controller.recipientCount(), 3);
        assertEq(controller.totalBps(), 301);

        controller.removeRecipient(a);
        assertEq(controller.recipientCount(), 2);
        assertEq(controller.totalBps(), 201);
        assertFalse(controller.isRecipient(a));
        assertTrue(controller.isRecipient(b));
        assertTrue(controller.isRecipient(l2Recipient));
    }

    function test_removeRecipient_rejectsMissing() public {
        address missing = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(EmissionsController.RecipientNotFound.selector, missing));
        controller.removeRecipient(missing);
    }

    function test_setRecipientBps_updatesTotalAndBoundary() public {
        controller.setRecipientBps(l2Recipient, 4_000);
        assertEq(controller.totalBps(), 4_000);

        controller.addRecipient(address(0xAAA1), 6_000, false);
        assertEq(controller.totalBps(), 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(EmissionsController.BpsOverflow.selector, uint256(10_001), uint256(10_000))
        );
        controller.setRecipientBps(address(0xAAA1), 6_001);

        vm.expectRevert(abi.encodeWithSelector(EmissionsController.InvalidBps.selector, uint256(0)));
        controller.setRecipientBps(l2Recipient, 0);
    }

    function test_setRecipientIsL2_toggles() public {
        controller.setRecipientIsL2(l2Recipient, false);
        EmissionsController.Recipient memory r = controller.recipientAt(0);
        assertFalse(r.isL2);
        controller.setRecipientIsL2(l2Recipient, true);
        r = controller.recipientAt(0);
        assertTrue(r.isL2);
    }

    function test_setRemainderSink_ownerOnlyAndUpdates() public {
        address nonOwner = address(0xBEEF);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        controller.setRemainderSink(address(0x1), false);

        controller.setRemainderSink(address(0xBADD), true);
        (address addr,, bool isL2) = controller.remainderSink();
        assertEq(addr, address(0xBADD));
        assertTrue(isL2);

        vm.expectRevert(EmissionsController.ZeroAddress.selector);
        controller.setRemainderSink(address(0), false);
    }

    // -----------------------------------------------------------------------
    // Distribution math
    // -----------------------------------------------------------------------

    function test_distribution_splitsBySharesAndRemainder() public {
        address a = address(0xAAA1); // L1
        address b = address(0xAAA2); // L1
        address c = address(0xAAA3); // L2
        controller.removeRecipient(l2Recipient);
        controller.addRecipient(a, 3_000, false);
        controller.addRecipient(b, 2_000, false);
        controller.addRecipient(c, 1_000, true);
        assertEq(controller.totalBps(), 6_000);

        vm.warp(controller.nextEpochReadyAt());
        (, uint256 amount) = controller.mintAndBridgeNextEpoch();
        assertEq(amount, 100);

        assertEq(token.balanceOf(a), 30);
        assertEq(token.balanceOf(b), 20);
        assertEq(token.balanceOf(address(bridge)), 10);
        assertEq(token.balanceOf(sinkAddr), 40); // 100 - 30 - 20 - 10
        assertEq(token.balanceOf(address(controller)), 0);
    }

    function test_distribution_revertsOnUnexpectedEtherWithoutL2Payouts() public {
        controller.removeRecipient(l2Recipient);
        controller.setRemainderSink(sinkAddr, false);

        vm.deal(address(this), 1);
        vm.warp(controller.nextEpochReadyAt());

        vm.expectRevert(abi.encodeWithSelector(EmissionsController.UnexpectedNativeValue.selector, uint256(1)));
        controller.mintAndBridgeNextEpoch{value: 1}();
    }

    function test_distribution_fullAllocation_noRemainder() public {
        address a = address(0xAAA1);
        controller.setRecipientBps(l2Recipient, 5_000);
        controller.addRecipient(a, 5_000, false);

        vm.warp(controller.nextEpochReadyAt());
        controller.mintAndBridgeNextEpoch();

        assertEq(token.balanceOf(a), 50);
        assertEq(token.balanceOf(address(bridge)), 50);
        assertEq(token.balanceOf(sinkAddr), 0);
    }

    function test_distribution_noRecipients_allToSink_L1() public {
        controller.removeRecipient(l2Recipient);
        controller.setRemainderSink(sinkAddr, false);

        vm.warp(controller.nextEpochReadyAt());
        controller.mintAndBridgeNextEpoch();

        assertEq(token.balanceOf(sinkAddr), 100);
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_distribution_noRecipients_allToSink_L2() public {
        controller.removeRecipient(l2Recipient);
        controller.setRemainderSink(sinkAddr, true);

        vm.warp(controller.nextEpochReadyAt());
        controller.mintAndBridgeNextEpoch();

        // Sink routed via bridge: bridge holds tokens, event attributes `to` = sinkAddr.
        assertEq(token.balanceOf(address(bridge)), 100);
        assertEq(token.balanceOf(sinkAddr), 0);
    }

    function test_distribution_requiresExplicitNativeValueSplitForMultipleL2Payouts() public {
        address a = address(0xAAA1);
        controller.setRecipientBps(l2Recipient, 5_000);
        controller.addRecipient(a, 5_000, true);

        vm.deal(address(this), 1);
        vm.warp(controller.nextEpochReadyAt());

        vm.expectRevert(abi.encodeWithSelector(EmissionsController.NativeValueSplitRequired.selector, uint256(2)));
        controller.mintAndBridgeNextEpoch{value: 1}();
    }

    function test_distribution_splitsExplicitNativeValuesAcrossL2Payouts() public {
        address a = address(0xAAA1);
        controller.setRecipientBps(l2Recipient, 5_000);
        controller.addRecipient(a, 5_000, true);

        uint256[] memory l2NativeValues = new uint256[](2);
        l2NativeValues[0] = 1;
        l2NativeValues[1] = 2;

        vm.deal(address(this), 3);
        vm.warp(controller.nextEpochReadyAt());

        controller.mintAndBridgeNextEpoch{value: 3}("", l2NativeValues);

        assertEq(token.balanceOf(address(bridge)), 100);
        assertEq(address(bridge).balance, 3);
        assertEq(bridge.depositCount(), 2);
        assertEq(bridge.depositRecipientAt(0), l2Recipient);
        assertEq(bridge.depositAmountAt(0), 50);
        assertEq(bridge.depositedValueAt(0), 1);
        assertEq(bridge.depositRecipientAt(1), a);
        assertEq(bridge.depositAmountAt(1), 50);
        assertEq(bridge.depositedValueAt(1), 2);
    }

    function test_distribution_roundingResidualLandsInSink() public {
        // Schedule amount = 100, BPS_DENOMINATOR = 10_000. Use a bps that doesn't divide evenly:
        // 3_333 bps of 100 = 33.33, floored to 33. Two such recipients take 66, sink gets 34.
        address a = address(0xAAA1);
        address b = address(0xAAA2);
        controller.removeRecipient(l2Recipient);
        controller.addRecipient(a, 3_333, false);
        controller.addRecipient(b, 3_333, false);

        vm.warp(controller.nextEpochReadyAt());
        controller.mintAndBridgeNextEpoch();

        assertEq(token.balanceOf(a), 33);
        assertEq(token.balanceOf(b), 33);
        assertEq(token.balanceOf(sinkAddr), 34);
    }

    function test_distribution_zeroShareSkipsPayout() public {
        // A recipient with a very small bps may floor to zero for a small epoch amount.
        // 1 bps of 100 = 0.01, floors to 0. Payout must skip; remainder absorbs.
        address tiny = address(0xBABE);
        controller.removeRecipient(l2Recipient);
        controller.addRecipient(tiny, 1, false);

        vm.warp(controller.nextEpochReadyAt());
        controller.mintAndBridgeNextEpoch();

        assertEq(token.balanceOf(tiny), 0);
        assertEq(token.balanceOf(sinkAddr), 100);
    }

    function test_distribution_emitsEpochDistributedAndPayouts() public {
        address a = address(0xAAA1);
        controller.setRecipientBps(l2Recipient, 5_000);
        controller.addRecipient(a, 3_000, false);

        vm.warp(controller.nextEpochReadyAt());

        vm.expectEmit(true, true, false, true);
        emit EmissionsController.EpochPayout(1, l2Recipient, true, 50);
        vm.expectEmit(true, true, false, true);
        emit EmissionsController.EpochPayout(1, a, false, 30);
        vm.expectEmit(true, true, false, true);
        emit EmissionsController.EpochPayout(1, sinkAddr, false, 20);
        vm.expectEmit(true, false, false, true);
        emit EmissionsController.EpochDistributed(1, 100, 80, 20, address(this));

        controller.mintAndBridgeNextEpoch();
    }
}
