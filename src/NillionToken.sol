// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable NIL token (6 decimals) for L1/L2 deployments.
contract NillionToken is ERC20, Ownable {
    mapping(address => bool) public minters;

    event MinterUpdated(address indexed minter, bool allowed);

    constructor(address owner_) ERC20("Nillion", "NIL") Ownable(owner_) {}

    function setMinter(address minter, bool allowed) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        minters[minter] = allowed;
        emit MinterUpdated(minter, allowed);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != owner() && !minters[msg.sender]) revert NotMinter();
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    error ZeroAddress();
    error NotMinter();
}
