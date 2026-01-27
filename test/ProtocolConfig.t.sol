// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../src/ProtocolConfig.sol";

contract DummyModule {}

contract ProtocolConfigTest is Test {
    function test_constructor_revertsOnZeroModules() public {
        vm.expectRevert(ProtocolConfig.ZeroAddress.selector);
        new ProtocolConfig(
            address(this),
            address(0),
            address(1),
            address(2),
            address(3),
            1,
            0,
            1,
            0,
            1,
            1,
            1,
            1,
            1,
            1
        );
    }

    function test_constructor_revertsOnInvalidBps() public {
        vm.expectRevert(abi.encodeWithSelector(ProtocolConfig.InvalidBps.selector, uint256(10001)));
        new ProtocolConfig(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            1,
            0,
            1,
            0,
            10001,
            1,
            1,
            1,
            1,
            1
        );
    }

    function test_setParams_validatesCommitteeCaps() public {
        ProtocolConfig cfg = new ProtocolConfig(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            2,
            0,
            5,
            1,
            5000,
            5000,
            10,
            10,
            100,
            1
        );

        vm.expectRevert(abi.encodeWithSelector(ProtocolConfig.InvalidCommitteeCap.selector, uint32(10), uint32(5)));
        cfg.setParams(10, 0, 5, 1, 5000, 5000, 10, 10, 100, 1);
    }

    function test_setModules_onlyOwner() public {
        ProtocolConfig cfg = new ProtocolConfig(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            2,
            0,
            5,
            1,
            5000,
            5000,
            10,
            10,
            100,
            1
        );

        DummyModule notOwnerModule1 = new DummyModule();
        DummyModule notOwnerModule2 = new DummyModule();
        DummyModule notOwnerModule3 = new DummyModule();
        DummyModule notOwnerModule4 = new DummyModule();
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        cfg.setModules(address(notOwnerModule1), address(notOwnerModule2), address(notOwnerModule3), address(notOwnerModule4));

        DummyModule module1 = new DummyModule();
        DummyModule module2 = new DummyModule();
        DummyModule module3 = new DummyModule();
        DummyModule module4 = new DummyModule();
        cfg.setModules(address(module1), address(module2), address(module3), address(module4));
        assertEq(cfg.stakingOps(), address(module1));
        assertEq(cfg.committeeSelector(), address(module2));
        assertEq(cfg.slashingPolicy(), address(module3));
        assertEq(cfg.rewardPolicy(), address(module4));
    }

    function test_setModules_rejectsEOA() public {
        ProtocolConfig cfg = new ProtocolConfig(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            2,
            0,
            5,
            1,
            5000,
            5000,
            10,
            10,
            100,
            1
        );

        DummyModule module2 = new DummyModule();
        DummyModule module3 = new DummyModule();
        DummyModule module4 = new DummyModule();

        vm.expectRevert(abi.encodeWithSelector(ProtocolConfig.InvalidModuleAddress.selector, address(0xBEEF)));
        cfg.setModules(address(0xBEEF), address(module2), address(module3), address(module4));
    }

    function test_setParams_updatesValues() public {
        ProtocolConfig cfg = new ProtocolConfig(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            2,
            0,
            5,
            1,
            5000,
            5000,
            10,
            10,
            100,
            1
        );

        cfg.setParams(3, 500, 6, 2, 4000, 6000, 20, 30, 50, 2);

        assertEq(cfg.baseCommitteeSize(), 3);
        assertEq(cfg.committeeSizeGrowthBps(), 500);
        assertEq(cfg.maxCommitteeSize(), 6);
        assertEq(cfg.maxEscalations(), 2);
        assertEq(cfg.quorumBps(), 4000);
        assertEq(cfg.verificationBps(), 6000);
        assertEq(cfg.responseWindow(), 20);
        assertEq(cfg.jailDuration(), 30);
        assertEq(cfg.maxVoteBatchSize(), 50);
        assertEq(cfg.minOperatorStake(), 2);
    }

    function test_setParams_onlyOwner() public {
        ProtocolConfig cfg = new ProtocolConfig(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            2,
            0,
            5,
            1,
            5000,
            5000,
            10,
            10,
            100,
            1
        );

        address nonOwner = address(0xBEEF);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        cfg.setParams(3, 0, 5, 1, 5000, 5000, 10, 10, 100, 1);
    }



    function test_setNodeVersion_onlyOwner() public {
        ProtocolConfig cfg = new ProtocolConfig(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            2,
            0,
            5,
            1,
            5000,
            5000,
            10,
            10,
            100,
            1
        );

        address nonOwner = address(0xBEEF);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        cfg.setNodeVersion("1.0.0");

        cfg.setNodeVersion("0.9.0");
        assertEq(cfg.nodeVersion(), "0.9.0");
    }
}
