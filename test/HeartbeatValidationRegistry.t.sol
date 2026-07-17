// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./helpers/BlacklightFixture.sol";
import "../src/Interfaces.sol";

/// @notice Mock validation registry that records callbacks from HeartbeatManager.
contract MockValidationRegistry is IValidationRegistry {
    struct Callback {
        bytes32 rawHTXHash;
        uint8 response;
        bytes32 heartbeatKey;
        address caller;
    }

    Callback[] public callbacks;

    function onHeartbeatFinalized(bytes32 rawHTXHash, uint8 response, bytes32 heartbeatKey) external override {
        callbacks.push(Callback(rawHTXHash, response, heartbeatKey, msg.sender));
    }

    function callbackCount() external view returns (uint256) {
        return callbacks.length;
    }

    function getCallback(uint256 i)
        external
        view
        returns (bytes32 rawHTXHash, uint8 response, bytes32 heartbeatKey, address caller)
    {
        Callback memory c = callbacks[i];
        return (c.rawHTXHash, c.response, c.heartbeatKey, c.caller);
    }
}

/// @notice Reverting validation registry — used to verify finalization is not blocked by a bad registry.
contract RevertingValidationRegistry is IValidationRegistry {
    function onHeartbeatFinalized(bytes32, uint8, bytes32) external pure override {
        revert("registry boom");
    }
}

contract HeartbeatValidationRegistryTest is BlacklightFixture {
    MockValidationRegistry internal registry;

    function setUp() public {
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 150e18;
        stakes[1] = 150e18;

        _deploySystem(
            2,
            stakes,
            2, // baseCommitteeSize
            2, // maxCommitteeSize
            5000, // quorumBps (50%)
            5000, // verificationBps (50%)
            1 days,
            7 days,
            0 // maxEscalations
        );

        registry = new MockValidationRegistry();
        manager.setValidationRegistry(address(registry));
    }

    function testSetValidationRegistryUpdatesAddress() public view {
        assertEq(manager.validationRegistry(), address(registry));
    }

    function testValidThresholdNotifiesValidationRegistry() public {
        (bytes32 hbKey, uint8 round,,, address[] memory members) = _submitPointerAndGetRound();
        bytes32 expectedRawHash = keccak256(_defaultRawHTX(1));

        // 50% valid vote meets quorum/verification thresholds.
        _vote(hbKey, round, members, members[0], 1);
        _finalizeDefault(hbKey, round);

        assertEq(registry.callbackCount(), 1, "registry not called");
        (bytes32 rawHTXHash, uint8 response, bytes32 heartbeatKey, address caller) = registry.getCallback(0);
        assertEq(rawHTXHash, expectedRawHash, "raw HTX hash mismatch");
        assertEq(uint256(response), 100, "valid response code mismatch");
        assertEq(heartbeatKey, hbKey, "heartbeat key mismatch");
        assertEq(caller, address(manager), "caller must be HeartbeatManager");
    }

    function testInvalidThresholdSendsZeroResponse() public {
        (bytes32 hbKey, uint8 round,,, address[] memory members) = _submitPointerAndGetRound();

        _vote(hbKey, round, members, members[0], 2);
        _finalizeDefault(hbKey, round);

        assertEq(registry.callbackCount(), 1);
        (, uint8 response,,) = registry.getCallback(0);
        assertEq(uint256(response), 0, "invalid response should be 0");
    }

    function testInconclusiveSendsFiftyResponse() public {
        (bytes32 hbKey, uint8 round,,,) = _submitPointerAndGetRound();

        // No votes — inconclusive.
        _finalizeDefault(hbKey, round);

        assertEq(registry.callbackCount(), 1);
        (, uint8 response,,) = registry.getCallback(0);
        assertEq(uint256(response), 50, "inconclusive response should be 50");
    }

    function testNoCallbackWhenRegistryUnset() public {
        manager.setValidationRegistry(address(0));

        (bytes32 hbKey, uint8 round,,, address[] memory members) = _submitPointerAndGetRound();
        _vote(hbKey, round, members, members[0], 1);
        _finalizeDefault(hbKey, round);

        assertEq(registry.callbackCount(), 0, "should not have called the old registry");
    }

    function testFinalizationSucceedsWhenRegistryReverts() public {
        RevertingValidationRegistry bad = new RevertingValidationRegistry();
        manager.setValidationRegistry(address(bad));

        (bytes32 hbKey, uint8 round,,, address[] memory members) = _submitPointerAndGetRound();
        _vote(hbKey, round, members, members[0], 1);

        // Finalization must still succeed even though the registry callback reverts.
        _finalizeDefault(hbKey, round);

        (HeartbeatManager.HeartbeatStatus status,,,,,,) = manager.heartbeats(hbKey);
        assertEq(uint8(status), uint8(HeartbeatManager.HeartbeatStatus.Verified));
    }

    function testNonOwnerCannotSetValidationRegistry() public {
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        vm.expectRevert();
        manager.setValidationRegistry(address(0xDEAD));
    }
}
