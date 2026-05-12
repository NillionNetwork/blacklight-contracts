// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../helpers/BlacklightFixture.sol";
import "../helpers/MerkleTestUtils.sol";

import "../../src/HeartbeatManager.sol";
import "../../src/StakingOperators.sol";
import "../../src/JailingPolicy.sol";
import "../../src/Interfaces.sol";

/// @notice Drives a single heartbeat round through vote/finalize/record/enforce
/// transitions, exercising the JailingPolicy state machine.
contract JailingHandler is Test {
    using MerkleTestUtils for bytes32[];
    using MerkleTestUtils for address[];

    HeartbeatManager public manager;
    StakingOperators public stakingOps;
    JailingPolicy public jailingPolicy;

    bytes32 public heartbeatKey;
    uint8 public round;
    address[] public members;
    bytes public rawHTX;

    // ghost state
    mapping(address => bool) public ghostVoted;
    mapping(address => uint8) public ghostVoteVerdict; // 1, 2 or 3
    mapping(address => bool) public ghostEnforced;
    mapping(address => uint64) public ghostEnforcedAt; // block.timestamp at enforcement
    uint256 public ghostEnforcedCount;

    constructor(
        HeartbeatManager _manager,
        StakingOperators _stakingOps,
        JailingPolicy _jailingPolicy,
        bytes32 _heartbeatKey,
        uint8 _round,
        address[] memory _members,
        bytes memory _rawHTX
    ) {
        manager = _manager;
        stakingOps = _stakingOps;
        jailingPolicy = _jailingPolicy;
        heartbeatKey = _heartbeatKey;
        round = _round;
        members = _members;
        rawHTX = _rawHTX;
    }

    function getMembers() external view returns (address[] memory) {
        return members;
    }

    function _roundMeta() internal view returns (uint64 deadline, bool finalized) {
        (,,,,,,,,, deadline, finalized,,,,,,,,) = manager.rounds(heartbeatKey, round);
    }

    function warp(uint256 secs) external {
        // Cap each warp to one third of jail duration so accumulated time
        // typically stays inside the jail window for invariant checks.
        uint256 dt = bound(secs, 0, 2 days);
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
    }

    function vote(uint256 idx, uint8 verdict) external {
        (uint64 deadline, bool finalized) = _roundMeta();
        if (finalized) return;
        if (block.timestamp > deadline) return;

        idx = idx % members.length;
        address voter = members[idx];
        if (ghostVoted[voter]) return;

        verdict = uint8(bound(verdict, 1, 3));
        bytes32[] memory proof = _proof(voter);
        vm.prank(voter);
        try manager.submitVerdict(heartbeatKey, verdict, proof) {
            ghostVoted[voter] = true;
            ghostVoteVerdict[voter] = verdict;
        } catch {}
    }

    function finalize() external {
        (uint64 deadline, bool finalized) = _roundMeta();
        if (finalized) return;
        if (block.timestamp <= deadline) return;
        try manager.escalateOrExpire(heartbeatKey, rawHTX) {} catch {}
    }

    function recordRound() external {
        (, bool finalized) = _roundMeta();
        if (!finalized) return;
        try jailingPolicy.recordRound(heartbeatKey, round) {} catch {}
    }

    function enforceOne(uint256 idx) external {
        idx = idx % members.length;
        address op = members[idx];
        if (ghostEnforced[op]) return;
        bytes32[] memory proof = _proof(op);
        try jailingPolicy.enforceJail(heartbeatKey, round, op, proof) {
            ghostEnforced[op] = true;
            ghostEnforcedAt[op] = uint64(block.timestamp);
            ghostEnforcedCount++;
        } catch {}
    }

    function enforceAll() external {
        try jailingPolicy.enforceJailFromMembers(heartbeatKey, round, members) {
            uint64 nowTs = uint64(block.timestamp);
            for (uint256 i = 0; i < members.length; i++) {
                address op = members[i];
                if (jailingPolicy.enforced(heartbeatKey, round, op) && !ghostEnforced[op]) {
                    ghostEnforced[op] = true;
                    ghostEnforcedAt[op] = nowTs;
                    ghostEnforcedCount++;
                }
            }
        } catch {}
    }

    function _proof(address member) internal view returns (bytes32[] memory proof) {
        (bool found, uint256 idx) = MerkleTestUtils.indexOf(members, member);
        require(found, "member not found");
        bytes32[] memory leaves = MerkleTestUtils.buildLeaves(address(manager), heartbeatKey, round, members);
        proof = MerkleTestUtils.proofForIndex(leaves, idx);
    }
}

contract JailingPolicyInvariants is StdInvariant, BlacklightFixture {
    JailingHandler internal handler;

    uint64 internal constant JAIL_DURATION = 7 days;
    uint32 internal constant COMMITTEE_SIZE = 10;

    function setUp() public {
        uint256 n = 20;
        uint256[] memory stakes = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            stakes[i] = 2e18;
        }

        _deploySystem(
            n,
            stakes,
            COMMITTEE_SIZE, // baseCommitteeSize
            COMMITTEE_SIZE, // maxCommitteeSize
            5000, // quorumBps
            5000, // verificationBps
            1 days, // responseWindow
            JAIL_DURATION,
            0 // maxEscalations -> finalize via expiry path
        );

        (bytes32 hbKey, uint8 r,,, address[] memory members) = _submitRawHTXAndGetRound();
        bytes memory raw = _defaultRawHTX(1);

        handler = new JailingHandler(manager, stakingOps, jailingPolicy, hbKey, r, members, raw);

        // Restrict fuzzing to the handler interface.
        targetContract(address(handler));

        bytes4[] memory sels = new bytes4[](6);
        sels[0] = JailingHandler.warp.selector;
        sels[1] = JailingHandler.vote.selector;
        sels[2] = JailingHandler.finalize.selector;
        sels[3] = JailingHandler.recordRound.selector;
        sels[4] = JailingHandler.enforceOne.selector;
        sels[5] = JailingHandler.enforceAll.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// @notice Once roundRecord is set, fields never change and stay consistent
    /// with what the manager finalized.
    function invariant_roundRecordImmutableAndConsistent() public view {
        bytes32 hbKey = handler.heartbeatKey();
        uint8 r = handler.round();

        (
            bool set,
            ISlashingPolicy.Outcome outcome,
            bytes32 root,
            address stakingAddr,
            uint64 jailDur,
            uint32 committeeSize
        ) = jailingPolicy.roundRecord(hbKey, r);

        if (!set) return;

        ISlashingPolicy.Outcome mgrOutcome = manager.roundOutcome(hbKey, r);
        assertEq(uint8(outcome), uint8(mgrOutcome), "policy outcome != manager outcome");
        assertEq(stakingAddr, address(stakingOps), "stakingOps mismatch");
        assertEq(jailDur, JAIL_DURATION, "jail duration mismatch");
        assertEq(committeeSize, COMMITTEE_SIZE, "committee size mismatch");
        assertTrue(root != bytes32(0), "committee root zero");
    }

    /// @notice Number of `enforced` flags set never exceeds the committee size,
    /// and matches the handler's monotonic ghost counter.
    function invariant_enforcedCountBoundedAndMatchesGhost() public view {
        bytes32 hbKey = handler.heartbeatKey();
        uint8 r = handler.round();
        address[] memory members = handler.getMembers();

        uint256 count;
        for (uint256 i = 0; i < members.length; i++) {
            if (jailingPolicy.enforced(hbKey, r, members[i])) count++;
        }
        assertLe(count, members.length, "enforced > committee");
        assertEq(count, handler.ghostEnforcedCount(), "enforced count != ghost");
    }

    /// @notice Operators that voted with the winning verdict (or the explicit
    /// inconclusive verdict 3) are never enforced.
    function invariant_correctVotersNeverEnforced() public view {
        bytes32 hbKey = handler.heartbeatKey();
        uint8 r = handler.round();
        address[] memory members = handler.getMembers();
        ISlashingPolicy.Outcome outcome = manager.roundOutcome(hbKey, r);

        for (uint256 i = 0; i < members.length; i++) {
            address op = members[i];
            if (!handler.ghostVoted(op)) continue;
            uint8 v = handler.ghostVoteVerdict(op);

            if (v == 3) {
                assertFalse(jailingPolicy.enforced(hbKey, r, op), "verdict==3 was enforced");
                continue;
            }
            if (outcome == ISlashingPolicy.Outcome.ValidThreshold && v == 1) {
                assertFalse(jailingPolicy.enforced(hbKey, r, op), "valid voter enforced");
            }
            if (outcome == ISlashingPolicy.Outcome.InvalidThreshold && v == 2) {
                assertFalse(jailingPolicy.enforced(hbKey, r, op), "invalid voter enforced");
            }
        }
    }

    /// @notice Inconclusive outcomes are never jailable for anyone.
    function invariant_inconclusiveOutcomeNoEnforcement() public view {
        bytes32 hbKey = handler.heartbeatKey();
        uint8 r = handler.round();
        if (manager.roundOutcome(hbKey, r) != ISlashingPolicy.Outcome.Inconclusive) return;

        address[] memory members = handler.getMembers();
        for (uint256 i = 0; i < members.length; i++) {
            assertFalse(jailingPolicy.enforced(hbKey, r, members[i]), "enforced under inconclusive");
        }
    }

    /// @notice An enforced operator must be jailed for the full jail duration
    /// after enforcement. We can't read `_jailedUntil` directly, but we can
    /// check `isJailed` while the jail window is still open.
    function invariant_enforcedImpliesJailedDuringWindow() public view {
        bytes32 hbKey = handler.heartbeatKey();
        uint8 r = handler.round();
        address[] memory members = handler.getMembers();

        for (uint256 i = 0; i < members.length; i++) {
            address op = members[i];
            if (!jailingPolicy.enforced(hbKey, r, op)) continue;

            uint64 enforcedAt = handler.ghostEnforcedAt(op);
            uint256 jailUntil = uint256(enforcedAt) + uint256(JAIL_DURATION);
            if (block.timestamp < jailUntil) {
                assertTrue(stakingOps.isJailed(op), "enforced operator not jailed within window");
            }
        }
    }

    /// @notice Recorded round metadata must match the live manager state.
    function invariant_recordedRootMatchesManagerRoot() public view {
        bytes32 hbKey = handler.heartbeatKey();
        uint8 r = handler.round();

        (bool set,, bytes32 policyRoot,,,) = jailingPolicy.roundRecord(hbKey, r);
        if (!set) return;

        (,,,,,,/*committeeSize*/ /*snapshotId*/, bytes32 mgrRoot,,,,,,,,,,,) = manager.rounds(hbKey, r);
        assertEq(policyRoot, mgrRoot, "policy committee root != manager root");
    }
}
