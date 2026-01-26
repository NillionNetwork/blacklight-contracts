// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "./helpers/BlacklightFixture.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract HeartbeatManagerConfigTest is BlacklightFixture {
    uint32 private constant BASE_COMMITTEE_SIZE = 4;
    uint32 private constant MAX_COMMITTEE_SIZE = 4;
    uint16 private constant QUORUM_BPS = 5000;
    uint16 private constant VERIFICATION_BPS = 5000;
    uint8 private constant MAX_ESCALATIONS = 0;
    uint256 private constant RESPONSE_WINDOW = 1 days;
    uint256 private constant JAIL_DURATION = 7 days;
    uint256 private constant MAX_VOTE_BATCH = 100;
    uint256 private constant MIN_OPERATOR_STAKE = 1e18;

    function setUp() public {
        uint256[] memory stakes = new uint256[](6);
        for (uint256 i = 0; i < stakes.length; i++) stakes[i] = 2e18;
        _deploySystem(
            6,
            stakes,
            BASE_COMMITTEE_SIZE,
            MAX_COMMITTEE_SIZE,
            QUORUM_BPS,
            VERIFICATION_BPS,
            RESPONSE_WINDOW,
            JAIL_DURATION,
            MAX_ESCALATIONS
        );
    }

    function _buildConfig(uint256 responseWindow) internal returns (ProtocolConfig) {
        return new ProtocolConfig(
            address(this),
            address(stakingOps),
            address(selector),
            address(jailingPolicy),
            address(rewardPolicy),
            BASE_COMMITTEE_SIZE,
            0,
            MAX_COMMITTEE_SIZE,
            MAX_ESCALATIONS,
            QUORUM_BPS,
            VERIFICATION_BPS,
            responseWindow,
            JAIL_DURATION,
            MAX_VOTE_BATCH,
            MIN_OPERATOR_STAKE
        );
    }

    function _roundResponseWindow(bytes32 hbKey, uint8 round) internal view returns (uint64) {
        (bool ok, bytes memory data) = address(manager).staticcall(
            abi.encodeWithSelector(manager.rounds.selector, hbKey, round)
        );
        require(ok, "rounds call failed");
        uint256 word;
        assembly ("memory-safe") {
            // ABI return layout: 19 words; responseWindowSec is index 17 (0-based).
            word := mload(add(data, 576))
        }
        return uint64(word);
    }

    function test_setConfig_onlyOwner_and_appliesToNewRounds() public {
        (bytes32 hbKey1, uint8 round1, , , ) = _submitRawHTXAndGetRound(1);
        assertEq(_roundResponseWindow(hbKey1, round1), RESPONSE_WINDOW);

        ProtocolConfig newConfig = _buildConfig(RESPONSE_WINDOW + 123);

        address nonOwner = address(0xBEEF);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        manager.setConfig(newConfig);

        manager.setConfig(newConfig);
        assertEq(address(manager.config()), address(newConfig));


        (bytes32 hbKey2, uint8 round2, , , ) = _submitRawHTXAndGetRound(2);
        assertEq(_roundResponseWindow(hbKey2, round2), RESPONSE_WINDOW + 123);
    }
}
