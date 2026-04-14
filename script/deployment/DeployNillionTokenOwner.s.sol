// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../../src/NillionToken.sol";
import "../../src/NillionTokenOwner.sol";

/// @notice Deploys NillionTokenOwner and transfers NillionToken ownership to it.
/// @dev This locks down direct minting by the token owner. Only whitelisted
///      minters (e.g. EmissionsController) can mint after this.
///
///      Configure via env vars:
///      - PRIVATE_KEY (required, must be the current token owner)
///      - L1_NIL_ADDRESS (required, address of the deployed NillionToken)
///      - TOKEN_OWNER_ADMIN (optional, admin of the new owner contract; defaults to deployer)
contract DeployNillionTokenOwner is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address tokenAddr = vm.envAddress("L1_NIL_ADDRESS");
        address admin = vm.envOr("TOKEN_OWNER_ADMIN", deployer);

        NillionToken token = NillionToken(tokenAddr);

        require(token.owner() == deployer, "deployer must be current token owner");

        vm.startBroadcast(deployerKey);

        NillionTokenOwner tokenOwner = new NillionTokenOwner(token, admin);
        console2.log("NillionTokenOwner deployed at:", address(tokenOwner));

        token.transferOwnership(address(tokenOwner));
        console2.log("Token ownership transferred to NillionTokenOwner");

        vm.stopBroadcast();

        // Verify post-conditions
        require(token.owner() == address(tokenOwner), "ownership transfer failed");
        console2.log("Admin:", admin);
        console2.log("Token:", tokenAddr);
    }
}
