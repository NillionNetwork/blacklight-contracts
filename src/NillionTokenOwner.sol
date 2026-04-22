// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./NillionToken.sol";

/// @title NillionTokenOwner
/// @notice Constrained owner for NillionToken that cannot call mint() directly.
/// @dev Transfer NillionToken ownership to this contract to enforce that only
///      whitelisted minters (e.g. EmissionsController) can mint. The admin of
///      this contract can still manage the minter whitelist and transfer token
///      ownership away if needed, but cannot bypass the minter restriction.
contract NillionTokenOwner is Ownable2Step {
    NillionToken public immutable token;

    error Unauthorized();

    constructor(NillionToken token_, address admin_) Ownable(admin_) {
        token = token_;
    }

    /// @notice Forward setMinter calls to the token.
    function setMinter(address minter, bool allowed) external onlyOwner {
        token.setMinter(minter, allowed);
    }

    /// @notice Transfer token ownership away (e.g. to a new constrained owner or governance).
    function transferTokenOwnership(address newOwner) external onlyOwner {
        token.transferOwnership(newOwner);
    }
}
