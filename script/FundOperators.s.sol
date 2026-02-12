// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/mocks/TESTToken.sol";
import "../src/mocks/BatchFunder.sol";
import "../src/StakingOperators.sol";

/// @title FundOperators
/// @notice Batch fund and stake for multiple operators efficiently
/// @dev Uses BatchFunder to mint TESTToken and stake in minimal transactions.
///
/// Configurable via environment variables:
///      - PRIVATE_KEY: Deployer private key (required, must be TESTToken owner)
///      - MNEMONIC: Mnemonic to derive operator addresses (required, uses BIP-44 derivation)
///      - STAKE_TOKEN: Address of the TESTToken contract (required)
///      - STAKING_OPERATORS: Address of the StakingOperators contract (required for staking)
///      - NUM_OPERATORS: Number of operators to fund (required, funds indices 0 to n-1)
///      - TOKEN_AMOUNT: Amount of tokens per operator (default: 10e6 = 100 tokens with 6 decimals)
///      - ETH_AMOUNT: Amount of ETH per operator in wei (default: 10e18 = 10 ETH)
///
/// @dev Performance: 4 transactions total
///          1. Deploy BatchFunder
///          2. Transfer token ownership to BatchFunder
///          3. batchFundAndStake() - funds + stakes ALL operators in ONE tx
///          4. Return token ownership
///          Note: BatchFunder becomes the staker (token holder) for all operators
///
contract FundOperators is Script {
    function run() external {
        // Read deployer key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Read contract addresses
        address stakeTokenAddr = vm.envAddress("STAKE_TOKEN");
        address stakingOpsAddr = vm.envAddress("STAKING_OPERATORS");

        // Read number of operators
        uint256 numOperators = vm.envUint("NUM_OPERATORS");

        // Read amounts
        uint256 tokenAmount = vm.envOr("TOKEN_AMOUNT", uint256(100e6)); // 100 tokens (6 decimals)
        uint256 ethAmount = vm.envOr("ETH_AMOUNT", uint256(1 ether)); // 10 ETH

        require(numOperators > 0, "NUM_OPERATORS must be > 0");
        require(stakeTokenAddr != address(0), "Invalid stake token");
        require(stakingOpsAddr != address(0), "Invalid staking operators");

        // Mnemonic to derive operator addresses
        string memory mnemonic = vm.envString("MNEMONIC");

        TESTToken token = TESTToken(stakeTokenAddr);

        // Generate operator addresses from mnemonic using BIP-44 derivation (indices 0 to n-1)
        address[] memory operators = new address[](numOperators);
        for (uint256 i = 0; i < numOperators; i++) {
            // Derive private key from mnemonic at index i (m/44'/60'/0'/0/{i})
            uint256 operatorPrivateKey = vm.deriveKey(mnemonic, uint32(i));
            operators[i] = vm.addr(operatorPrivateKey);
        }

        // Deploy BatchFunder and execute batch operation
        vm.startBroadcast(deployerPrivateKey);

        BatchFunder batchFunder = new BatchFunder(stakeTokenAddr, stakingOpsAddr);
        token.transferOwnership(address(batchFunder));

        uint256 totalEth = ethAmount * numOperators;
        batchFunder.batchFundAndStake{value: totalEth}(operators, tokenAmount, ethAmount);
        batchFunder.returnTokenOwnership(deployer);

        vm.stopBroadcast();
    }
}
