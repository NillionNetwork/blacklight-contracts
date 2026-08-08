// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockL1StandardBridge {
    error IncorrectValue(uint256 provided, uint256 expected);

    event Deposit(address indexed l1Token, address indexed to, uint256 amount, uint256 value);

    bool public enforceRequiredValue;
    uint256 public requiredValue;
    uint256 public depositCount;
    mapping(uint256 => address) public depositRecipientAt;
    mapping(uint256 => uint256) public depositAmountAt;
    mapping(uint256 => uint256) public depositedValueAt;

    function setRequiredValue(uint256 value) external {
        enforceRequiredValue = true;
        requiredValue = value;
    }

    function depositERC20To(
        address l1Token,
        address, /* l2Token */
        address to,
        uint256 amount,
        uint32, /* l2Gas */
        bytes calldata /* data */
    )
        external
        payable
    {
        if (enforceRequiredValue && msg.value != requiredValue) revert IncorrectValue(msg.value, requiredValue);

        IERC20(l1Token).transferFrom(msg.sender, address(this), amount);
        uint256 depositIndex = depositCount;
        depositCount = depositIndex + 1;
        depositRecipientAt[depositIndex] = to;
        depositAmountAt[depositIndex] = amount;
        depositedValueAt[depositIndex] = msg.value;

        emit Deposit(l1Token, to, amount, msg.value);
    }
}
