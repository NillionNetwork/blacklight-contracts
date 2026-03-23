// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 that deducts a percentage fee on every transfer/transferFrom.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public feeBps; // e.g. 500 = 5%

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        _burn(msg.sender, fee);
        return super.transfer(to, amount - fee);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        _spendAllowance(from, msg.sender, amount);
        _burn(from, fee);
        _transfer(from, to, amount - fee);
        return true;
    }
}
