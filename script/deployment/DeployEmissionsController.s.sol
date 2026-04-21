// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../../src/EmissionsController.sol";

/// @notice Deploys EmissionsController with a provided emissions schedule, recipient list, and
///         remainder sink. Recipients and sink can be updated post-deployment by the owner.
/// @dev Configure via env vars when running `forge script`:
///      Required:
///        - PRIVATE_KEY
///        - TOKEN (IERC20Mintable)
///        - L1_BRIDGE (IL1StandardBridge)
///        - L2_TOKEN
///        - REMAINDER_SINK_ADDR (unallocated emissions go here)
///      Optional:
///        - OWNER (defaults to deployer)
///        - REMAINDER_SINK_IS_L2 (default: true)
///        - RECIPIENT_ADDRS (comma-separated addresses; default: empty)
///        - RECIPIENT_BPS (comma-separated uints; must match RECIPIENT_ADDRS length)
///        - RECIPIENT_IS_L2 (comma-separated 0/1 flags; must match RECIPIENT_ADDRS length)
///        - EPOCH_START (default: block.timestamp)
///        - EPOCH_DURATION (seconds, default: 7 days)
///        - L2_GAS_LIMIT (default: 200_000)
///        - GLOBAL_MINT_CAP (default: 0 = unlimited)
///        - EMISSIONS_SCHEDULE (comma-separated uints; default: [0])
///
///      `REMAINDER_SINK_ADDR` is required; there is no legacy fallback to `L2_RECIPIENT`.
///      Configure recipient allocation explicitly via `RECIPIENT_*`.
contract DeployEmissionsController is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address owner = vm.envOr("OWNER", deployer);
        address tokenAddr = vm.envAddress("TOKEN");
        address bridgeAddr = vm.envAddress("L1_BRIDGE");
        address l2TokenAddr = vm.envAddress("L2_TOKEN");

        (address sinkAddr, bool sinkIsL2) = _readSink();

        uint256 startTime = vm.envOr("EPOCH_START", block.timestamp);
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(7 days));
        uint32 l2GasLimit = uint32(vm.envOr("L2_GAS_LIMIT", uint256(200_000)));
        uint256 globalCap = vm.envOr("GLOBAL_MINT_CAP", uint256(0));

        uint256[] memory schedule = vm.envOr("EMISSIONS_SCHEDULE", ",", _defaultSchedule());
        require(schedule.length > 0, "empty schedule");

        EmissionsController.Recipient memory sink =
            EmissionsController.Recipient({addr: sinkAddr, bps: 0, isL2: sinkIsL2});
        EmissionsController.Recipient[] memory initial = _readRecipients();
        _assertBpsSum(initial);

        vm.startBroadcast(deployerKey);

        EmissionsController controller = new EmissionsController(
            IERC20Mintable(tokenAddr),
            IL1StandardBridge(bridgeAddr),
            l2TokenAddr,
            sink,
            initial,
            startTime,
            epochDuration,
            l2GasLimit,
            globalCap,
            schedule,
            owner
        );

        vm.stopBroadcast();

        console2.log("EmissionsController:", address(controller));
        console2.log("Owner:", owner);
        console2.log("RemainderSink:", sinkAddr, sinkIsL2 ? "(L2)" : "(L1)");
        console2.log("InitialRecipients:", initial.length);
        for (uint256 i = 0; i < initial.length; i++) {
            console2.log(" -", initial[i].addr, initial[i].bps, initial[i].isL2 ? "(L2)" : "(L1)");
        }
    }

    function _readSink() internal view returns (address addr, bool isL2) {
        addr = vm.envAddress("REMAINDER_SINK_ADDR");
        isL2 = vm.envOr("REMAINDER_SINK_IS_L2", true);
    }

    function _readRecipients() internal view returns (EmissionsController.Recipient[] memory out) {
        address[] memory emptyAddrs = new address[](0);
        uint256[] memory emptyUints = new uint256[](0);

        address[] memory addrs = vm.envOr("RECIPIENT_ADDRS", ",", emptyAddrs);
        uint256[] memory bps = vm.envOr("RECIPIENT_BPS", ",", emptyUints);
        uint256[] memory isL2Flags = vm.envOr("RECIPIENT_IS_L2", ",", emptyUints);

        require(
            addrs.length == bps.length && addrs.length == isL2Flags.length,
            "RECIPIENT_ADDRS / RECIPIENT_BPS / RECIPIENT_IS_L2 length mismatch"
        );

        out = new EmissionsController.Recipient[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            require(bps[i] > 0 && bps[i] <= type(uint16).max, "bps out of range");
            out[i] = EmissionsController.Recipient({addr: addrs[i], bps: uint16(bps[i]), isL2: isL2Flags[i] != 0});
        }
    }

    function _assertBpsSum(EmissionsController.Recipient[] memory rs) internal pure {
        uint256 total;
        for (uint256 i = 0; i < rs.length; i++) {
            total += rs[i].bps;
        }
        require(total <= 10_000, "sum(recipient bps) > 10_000");
    }

    function _defaultSchedule() internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = 0;
    }
}
