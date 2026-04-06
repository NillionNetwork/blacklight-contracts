// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../StakingOperators.sol";
import "./TESTToken.sol";

/// @title BatchFunder
/// @notice Helper contract to batch fund and stake operators in minimal transactions
/// @dev Used for local testing to speed up operator funding.
///      The deployer must transfer TESTToken ownership to this contract for minting,
///      then call returnTokenOwnership() to get it back.
contract BatchFunder is Ownable {
    TESTToken public immutable token;
    StakingOperators public immutable staking;

    constructor(address _token, address _staking) Ownable(msg.sender) {
        token = TESTToken(_token);
        staking = StakingOperators(_staking);
    }

    /// @notice Batch mint tokens to multiple addresses
    /// @dev Requires this contract to be the token owner
    /// @param recipients Array of addresses to mint to
    /// @param amount Amount to mint to each address
    function batchMint(address[] calldata recipients, uint256 amount) external onlyOwner {
        for (uint256 i = 0; i < recipients.length; i++) {
            token.mint(recipients[i], amount);
        }
    }

    /// @notice Batch send ETH to multiple addresses
    /// @param recipients Array of addresses to send ETH to
    /// @param amount Amount of ETH to send to each address
    function batchSendETH(address[] calldata recipients, uint256 amount) external payable onlyOwner {
        require(msg.value >= recipients.length * amount, "Insufficient ETH");

        for (uint256 i = 0; i < recipients.length; i++) {
            (bool success,) = recipients[i].call{value: amount}("");
            require(success, "ETH transfer failed");
        }

        // Refund excess ETH
        uint256 excess = msg.value - (recipients.length * amount);
        if (excess > 0) {
            (bool success,) = msg.sender.call{value: excess}("");
            require(success, "Refund failed");
        }
    }

    /// @notice Combined batch operation: mint tokens and send ETH to all recipients
    /// @dev Requires this contract to be the token owner
    /// @param recipients Array of addresses
    /// @param tokenAmount Amount of tokens to mint to each
    /// @param ethAmount Amount of ETH to send to each
    function batchFund(address[] calldata recipients, uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        onlyOwner
    {
        require(msg.value >= recipients.length * ethAmount, "Insufficient ETH");

        for (uint256 i = 0; i < recipients.length; i++) {
            // Mint tokens
            token.mint(recipients[i], tokenAmount);

            // Send ETH
            (bool success,) = recipients[i].call{value: ethAmount}("");
            require(success, "ETH transfer failed");
        }

        // Refund excess ETH
        uint256 excess = msg.value - (recipients.length * ethAmount);
        if (excess > 0) {
            (bool success,) = msg.sender.call{value: excess}("");
            require(success, "Refund failed");
        }
    }

    /// @notice Batch fund and stake: mint tokens to this contract, stake to operators, send ETH
    /// @dev This is the most efficient method - reduces funding+staking to 4 total transactions.
    ///      The BatchFunder becomes the staker for all operators (holds the tokens).
    ///      Operators only receive ETH for gas. This is ideal for nodes controlled by one owner.
    /// @param operators Array of operator addresses to fund and stake to
    /// @param tokenAmount Amount of tokens to stake per operator
    /// @param ethAmount Amount of ETH to send per operator
    function batchFundAndStake(address[] calldata operators, uint256 tokenAmount, uint256 ethAmount)
        external
        payable
        onlyOwner
    {
        require(msg.value >= operators.length * ethAmount, "Insufficient ETH");

        // Mint all tokens to this contract
        uint256 totalTokens = tokenAmount * operators.length;
        token.mint(address(this), totalTokens);

        // Approve staking contract once for all stakes
        token.approve(address(staking), totalTokens);

        // Stake to each operator and send ETH
        for (uint256 i = 0; i < operators.length; i++) {
            // Stake: this contract becomes the staker for the operator
            staking.stakeTo(operators[i], tokenAmount);

            // Send ETH to operator for gas (all addresses already have ETH in Anvil)
            // (bool success,) = operators[i].call{value: ethAmount}("");
            //require(success, "ETH transfer failed");
        }

        // Refund excess ETH
        uint256 excess = msg.value - (operators.length * ethAmount);
        if (excess > 0) {
            (bool success,) = msg.sender.call{value: excess}("");
            require(success, "Refund failed");
        }
    }

    /// @notice Return token ownership back to the original owner
    /// @param newOwner Address to transfer token ownership to
    function returnTokenOwnership(address newOwner) external onlyOwner {
        token.transferOwnership(newOwner);
    }

    /// @notice Allow this contract to receive ETH
    receive() external payable {}
}
