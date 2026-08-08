// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IL1StandardBridge {
    function depositERC20To(
        address _l1Token,
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _l2Gas,
        bytes calldata _data
    ) external payable;
}

interface IERC20Mintable is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title EmissionsController
/// @notice Mints token emissions on L1 on a fixed schedule and distributes each epoch across a
///         mutable list of L1 and L2 recipients by basis points. Any unallocated fraction of the
///         epoch (when the recipient bps do not sum to 10_000) is forwarded to a configurable
///         remainder sink.
/// @dev The emission schedule itself is immutable after deployment. The recipient registry and
///      remainder sink are governed by the contract owner. Triggering an epoch remains
///      permissionless once the epoch is ready.
contract EmissionsController is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Basis-points denominator. A recipient with `bps == BPS_DENOMINATOR` receives the
    ///         full epoch amount; the sum of all recipient bps may never exceed this value.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard cap on the number of distinct recipients to bound the per-epoch gas cost.
    uint256 public constant MAX_RECIPIENTS = 32;

    struct Recipient {
        address addr;
        uint16 bps;
        bool isL2;
    }

    error ZeroAddress();
    error ZeroEpochDuration();
    error EmptySchedule();
    error EpochNotElapsed(uint256 currentTime, uint256 readyAt);
    error NoRemainingEpochs();
    /// @notice Raised when a mint would exceed the global cap.
    /// @param requested The epoch emission amount.
    /// @param remaining Remaining mintable amount under the cap.
    error GlobalCapExceeded(uint256 requested, uint256 remaining);
    error InvalidEpoch(uint256 epochId);
    error ValueWithZeroEmission();
    error RecipientExists(address addr);
    error RecipientNotFound(address addr);
    error BpsOverflow(uint256 requested, uint256 max);
    error InvalidBps(uint256 bps);
    error TooManyRecipients(uint256 max);
    error RemainderSinkUnset();
    error NativeValueSplitRequired(uint256 l2PayoutCount);
    error NativeValueCountMismatch(uint256 provided, uint256 expected);
    error NativeValueSumMismatch(uint256 provided, uint256 expected);
    error UnexpectedNativeValue(uint256 value);

    event EpochDistributed(
        uint256 indexed epoch, uint256 amount, uint256 distributed, uint256 remainder, address indexed caller
    );
    event EpochPayout(uint256 indexed epoch, address indexed to, bool isL2, uint256 amount);
    event RecipientAdded(address indexed addr, uint16 bps, bool isL2);
    event RecipientRemoved(address indexed addr);
    event RecipientBpsUpdated(address indexed addr, uint16 oldBps, uint16 newBps);
    event RecipientIsL2Updated(address indexed addr, bool oldIsL2, bool newIsL2);
    event RemainderSinkUpdated(address oldAddr, bool oldIsL2, address newAddr, bool newIsL2);
    event BridgeApprovalSet(address indexed token, address indexed bridge, uint256 allowance);
    event L2GasLimitUpdated(uint32 oldLimit, uint32 newLimit);

    IERC20Mintable public immutable token;
    IL1StandardBridge public immutable bridge;
    address public immutable l2Token;
    uint256 public immutable startTime;
    uint256 public immutable epochDuration;
    uint256 public immutable globalMintCap;

    uint32 public l2GasLimit;

    uint256 public mintedEpochs;
    uint256 public mintedTotal;

    uint256[] private _emissionsPerEpoch;
    bytes32 public immutable emissionsPerEpochHash;
    uint256 public immutable emissionsPerEpochCount;

    // Recipient registry.
    address[] private _recipientList;
    mapping(address => Recipient) private _recipients;
    mapping(address => uint256) private _recipientIndex; // 1-based; 0 == not present.
    uint256 public totalBps;

    Recipient public remainderSink;

    constructor(
        IERC20Mintable _token,
        IL1StandardBridge _bridge,
        address _l2Token,
        Recipient memory _initialSink,
        Recipient[] memory _initialRecipients,
        uint256 _startTime,
        uint256 _epochDuration,
        uint32 _l2GasLimit,
        uint256 _globalMintCap,
        uint256[] memory emissionsSchedule,
        address _owner
    ) Ownable(_owner) {
        if (address(_token) == address(0)) revert ZeroAddress();
        if (address(_bridge) == address(0)) revert ZeroAddress();
        if (_l2Token == address(0)) revert ZeroAddress();
        if (_epochDuration == 0) revert ZeroEpochDuration();
        if (emissionsSchedule.length == 0) revert EmptySchedule();

        token = _token;
        bridge = _bridge;
        l2Token = _l2Token;
        startTime = _startTime;
        epochDuration = _epochDuration;
        l2GasLimit = _l2GasLimit;
        globalMintCap = _globalMintCap;
        _emissionsPerEpoch = emissionsSchedule;
        emissionsPerEpochHash = keccak256(abi.encode(emissionsSchedule));
        emissionsPerEpochCount = emissionsSchedule.length;

        _setRemainderSink(_initialSink.addr, _initialSink.isL2);

        uint256 n = _initialRecipients.length;
        for (uint256 i = 0; i < n; i++) {
            Recipient memory r = _initialRecipients[i];
            _addRecipient(r.addr, r.bps, r.isL2);
        }

        _setBridgeApproval();
    }

    // -----------------------------------------------------------------------
    // Admin: recipient registry
    // -----------------------------------------------------------------------

    /// @notice Register a new distribution recipient.
    function addRecipient(address addr, uint16 bps, bool isL2) external onlyOwner {
        _addRecipient(addr, bps, isL2);
    }

    /// @notice Remove a recipient from the distribution list. Frees the bps share.
    function removeRecipient(address addr) external onlyOwner {
        uint256 idx1 = _recipientIndex[addr];
        if (idx1 == 0) revert RecipientNotFound(addr);

        uint16 oldBps = _recipients[addr].bps;
        totalBps -= oldBps;

        uint256 lastIdx = _recipientList.length - 1;
        uint256 idx = idx1 - 1;
        if (idx != lastIdx) {
            address lastAddr = _recipientList[lastIdx];
            _recipientList[idx] = lastAddr;
            _recipientIndex[lastAddr] = idx1;
        }
        _recipientList.pop();
        delete _recipientIndex[addr];
        delete _recipients[addr];

        emit RecipientRemoved(addr);
    }

    /// @notice Update the bps share of an existing recipient. Must stay within the global cap.
    function setRecipientBps(address addr, uint16 newBps) external onlyOwner {
        if (newBps == 0) revert InvalidBps(newBps);
        uint256 idx1 = _recipientIndex[addr];
        if (idx1 == 0) revert RecipientNotFound(addr);

        Recipient storage r = _recipients[addr];
        uint16 oldBps = r.bps;
        uint256 newTotal = totalBps - oldBps + newBps;
        if (newTotal > BPS_DENOMINATOR) revert BpsOverflow(newTotal, BPS_DENOMINATOR);

        r.bps = newBps;
        totalBps = newTotal;

        emit RecipientBpsUpdated(addr, oldBps, newBps);
    }

    /// @notice Toggle whether an existing recipient receives via L1 transfer or L2 bridge.
    function setRecipientIsL2(address addr, bool isL2) external onlyOwner {
        uint256 idx1 = _recipientIndex[addr];
        if (idx1 == 0) revert RecipientNotFound(addr);

        Recipient storage r = _recipients[addr];
        bool oldIsL2 = r.isL2;
        if (oldIsL2 == isL2) return;
        r.isL2 = isL2;

        emit RecipientIsL2Updated(addr, oldIsL2, isL2);
    }

    /// @notice Update the remainder sink that receives any unallocated epoch amount.
    function setRemainderSink(address addr, bool isL2) external onlyOwner {
        _setRemainderSink(addr, isL2);
    }

    function setL2GasLimit(uint32 newLimit) external onlyOwner {
        emit L2GasLimitUpdated(l2GasLimit, newLimit);
        l2GasLimit = newLimit;
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function epochs() external view returns (uint256) {
        return emissionsPerEpochCount;
    }

    function emissionForEpoch(uint256 epochId) external view returns (uint256) {
        if (epochId == 0 || epochId > emissionsPerEpochCount) revert InvalidEpoch(epochId);
        return _emissionsPerEpoch[epochId - 1];
    }

    function nextEpochReadyAt() public view returns (uint256) {
        if (mintedEpochs >= emissionsPerEpochCount) return type(uint256).max;
        return startTime + epochDuration * mintedEpochs;
    }

    function recipientCount() external view returns (uint256) {
        return _recipientList.length;
    }

    function recipientAt(uint256 i) external view returns (Recipient memory) {
        return _recipients[_recipientList[i]];
    }

    function recipients() external view returns (Recipient[] memory out) {
        uint256 n = _recipientList.length;
        out = new Recipient[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _recipients[_recipientList[i]];
        }
    }

    function isRecipient(address addr) external view returns (bool) {
        return _recipientIndex[addr] != 0;
    }

    // -----------------------------------------------------------------------
    // Minting / distribution
    // -----------------------------------------------------------------------

    function mintAndBridgeNextEpoch() external payable nonReentrant returns (uint256 epochId, uint256 amount) {
        return _mintAndDistributeNextEpoch("", new uint256[](0));
    }

    function mintAndBridgeNextEpoch(bytes calldata bridgeData)
        external
        payable
        nonReentrant
        returns (uint256 epochId, uint256 amount)
    {
        return _mintAndDistributeNextEpoch(bridgeData, new uint256[](0));
    }

    function mintAndBridgeNextEpoch(bytes calldata bridgeData, uint256[] calldata l2NativeValues)
        external
        payable
        nonReentrant
        returns (uint256 epochId, uint256 amount)
    {
        return _mintAndDistributeNextEpoch(bridgeData, l2NativeValues);
    }

    function _mintAndDistributeNextEpoch(bytes memory bridgeData, uint256[] memory l2NativeValues)
        internal
        returns (uint256 epochId, uint256 amount)
    {
        uint256 mintedSoFar = mintedEpochs;
        if (mintedSoFar >= emissionsPerEpochCount) revert NoRemainingEpochs();

        epochId = mintedSoFar + 1;
        uint256 readyAt = nextEpochReadyAt();
        if (block.timestamp < readyAt) revert EpochNotElapsed(block.timestamp, readyAt);

        amount = _emissionsPerEpoch[epochId - 1];
        if (amount == 0 && msg.value != 0) revert ValueWithZeroEmission();

        if (globalMintCap != 0) {
            if (mintedTotal >= globalMintCap) revert GlobalCapExceeded(amount, 0);
            uint256 remaining = globalMintCap - mintedTotal;
            if (amount > remaining) revert GlobalCapExceeded(amount, remaining);
        }

        mintedEpochs = mintedSoFar + 1;
        mintedTotal += amount;

        uint256 distributed;
        if (amount != 0) {
            uint256 l2PayoutCount = _countL2Payouts(amount);
            _validateNativeValues(l2PayoutCount, l2NativeValues);

            token.mint(address(this), amount);

            uint256 n = _recipientList.length;
            uint256 l2PayoutIndex;
            for (uint256 i = 0; i < n; i++) {
                Recipient memory r = _recipients[_recipientList[i]];
                uint256 share = (amount * r.bps) / BPS_DENOMINATOR;
                if (share == 0) continue;
                uint256 nativeValue;
                if (r.isL2) {
                    nativeValue = _nativeValueForL2Payout(l2PayoutIndex, l2PayoutCount, l2NativeValues);
                    l2PayoutIndex++;
                }
                _payout(epochId, r, share, nativeValue, bridgeData);
                distributed += share;
            }

            uint256 remainder = amount - distributed;
            if (remainder > 0) {
                Recipient memory sink = remainderSink;
                if (sink.addr == address(0)) revert RemainderSinkUnset();
                uint256 nativeValue;
                if (sink.isL2) {
                    nativeValue = _nativeValueForL2Payout(l2PayoutIndex, l2PayoutCount, l2NativeValues);
                }
                _payout(epochId, sink, remainder, nativeValue, bridgeData);
            }
        }

        emit EpochDistributed(epochId, amount, distributed, amount - distributed, msg.sender);
    }

    function _payout(uint256 epochId, Recipient memory r, uint256 share, uint256 nativeValue, bytes memory bridgeData)
        internal
    {
        if (r.isL2) {
            bridge.depositERC20To{value: nativeValue}(address(token), l2Token, r.addr, share, l2GasLimit, bridgeData);
        } else {
            IERC20(address(token)).safeTransfer(r.addr, share);
        }
        emit EpochPayout(epochId, r.addr, r.isL2, share);
    }

    function ensureBridgeApproval() external {
        _setBridgeApproval();
    }

    function _setBridgeApproval() internal {
        IERC20 erc20 = IERC20(address(token));
        uint256 currentAllowance = erc20.allowance(address(this), address(bridge));
        if (currentAllowance != type(uint256).max) {
            SafeERC20.forceApprove(erc20, address(bridge), type(uint256).max);
            emit BridgeApprovalSet(address(token), address(bridge), type(uint256).max);
        }
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _addRecipient(address addr, uint16 bps, bool isL2) internal {
        if (addr == address(0)) revert ZeroAddress();
        if (bps == 0) revert InvalidBps(bps);
        if (_recipientIndex[addr] != 0) revert RecipientExists(addr);
        if (_recipientList.length >= MAX_RECIPIENTS) revert TooManyRecipients(MAX_RECIPIENTS);

        uint256 newTotal = totalBps + bps;
        if (newTotal > BPS_DENOMINATOR) revert BpsOverflow(newTotal, BPS_DENOMINATOR);

        _recipients[addr] = Recipient({addr: addr, bps: bps, isL2: isL2});
        _recipientList.push(addr);
        _recipientIndex[addr] = _recipientList.length;
        totalBps = newTotal;

        emit RecipientAdded(addr, bps, isL2);
    }

    function _setRemainderSink(address addr, bool isL2) internal {
        if (addr == address(0)) revert ZeroAddress();
        Recipient memory oldSink = remainderSink;
        remainderSink = Recipient({addr: addr, bps: 0, isL2: isL2});
        emit RemainderSinkUpdated(oldSink.addr, oldSink.isL2, addr, isL2);
    }

    function _countL2Payouts(uint256 amount) internal view returns (uint256 l2PayoutCount) {
        uint256 n = _recipientList.length;
        uint256 distributed;

        for (uint256 i = 0; i < n; i++) {
            Recipient memory r = _recipients[_recipientList[i]];
            uint256 share = (amount * r.bps) / BPS_DENOMINATOR;
            if (share == 0) continue;
            if (r.isL2) l2PayoutCount++;
            distributed += share;
        }

        uint256 remainder = amount - distributed;
        if (remainder > 0 && remainderSink.isL2) l2PayoutCount++;
    }

    function _validateNativeValues(uint256 l2PayoutCount, uint256[] memory l2NativeValues) internal view {
        uint256 suppliedValue = msg.value;
        uint256 providedValues = l2NativeValues.length;

        if (providedValues == 0) {
            if (suppliedValue == 0) return;
            if (l2PayoutCount == 0) revert UnexpectedNativeValue(suppliedValue);
            if (l2PayoutCount > 1) revert NativeValueSplitRequired(l2PayoutCount);
            return;
        }

        if (providedValues != l2PayoutCount) revert NativeValueCountMismatch(providedValues, l2PayoutCount);

        uint256 totalExplicitValue;
        for (uint256 i = 0; i < providedValues; i++) {
            totalExplicitValue += l2NativeValues[i];
        }
        if (totalExplicitValue != suppliedValue) revert NativeValueSumMismatch(totalExplicitValue, suppliedValue);
    }

    function _nativeValueForL2Payout(uint256 l2PayoutIndex, uint256 l2PayoutCount, uint256[] memory l2NativeValues)
        internal
        view
        returns (uint256)
    {
        if (l2NativeValues.length != 0) {
            return l2NativeValues[l2PayoutIndex];
        }
        if (msg.value != 0 && l2PayoutCount == 1) {
            return msg.value;
        }
        return 0;
    }
}
