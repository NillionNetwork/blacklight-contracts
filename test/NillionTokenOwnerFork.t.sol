// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../src/NillionToken.sol";
import "../src/NillionTokenOwner.sol";

/// @notice Fork-based e2e test for the NillionTokenOwner migration.
/// @dev Run with: L1_RPC_URL=<rpc> L1_NIL_ADDRESS=<addr> forge test --match-contract NillionTokenOwnerForkTest -vv
///      Skips automatically when env vars are not set.
contract NillionTokenOwnerForkTest is Test {
    NillionToken token;
    NillionTokenOwner tokenOwner;

    address originalOwner;
    address admin;

    function setUp() public {
        // Skip if fork env vars are not configured
        try vm.envString("L1_RPC_URL") returns (string memory rpcUrl) {
            try vm.envAddress("L1_NIL_ADDRESS") returns (address tokenAddr) {
                vm.createSelectFork(rpcUrl);
                token = NillionToken(tokenAddr);
                originalOwner = token.owner();
                admin = originalOwner; // admin inherits from current owner
            } catch {
                vm.skip(true);
            }
        } catch {
            vm.skip(true);
        }
    }

    function test_fullMigration_locksDownMinting() public {
        // --- Pre-migration: owner can mint ---
        vm.prank(originalOwner);
        token.mint(address(0xDEAD), 1);

        // --- Deploy NillionTokenOwner ---
        vm.prank(originalOwner);
        tokenOwner = new NillionTokenOwner(token, admin);

        // --- Transfer ownership ---
        vm.prank(originalOwner);
        token.transferOwnership(address(tokenOwner));

        assertEq(token.owner(), address(tokenOwner));

        // --- Post-migration: original owner can no longer mint ---
        vm.prank(originalOwner);
        vm.expectRevert(NillionToken.NotMinter.selector);
        token.mint(address(0xDEAD), 1);
    }

    function test_fullMigration_minterStillWorks() public {
        address minter = address(0xFEED);

        // --- Setup: add a minter before migration ---
        vm.prank(originalOwner);
        token.setMinter(minter, true);

        // --- Deploy & transfer ---
        vm.startPrank(originalOwner);
        tokenOwner = new NillionTokenOwner(token, admin);
        token.transferOwnership(address(tokenOwner));
        vm.stopPrank();

        // --- Existing minter still works ---
        uint256 balBefore = token.balanceOf(address(0xBEEF));
        vm.prank(minter);
        token.mint(address(0xBEEF), 100);
        assertEq(token.balanceOf(address(0xBEEF)), balBefore + 100);
    }

    function test_fullMigration_adminCanManageMinters() public {
        address minter = address(0xFEED);

        // --- Deploy & transfer ---
        vm.startPrank(originalOwner);
        tokenOwner = new NillionTokenOwner(token, admin);
        token.transferOwnership(address(tokenOwner));
        vm.stopPrank();

        // --- Admin can add minters through the constrained owner ---
        vm.prank(admin);
        tokenOwner.setMinter(minter, true);
        assertTrue(token.minters(minter));

        // --- Admin can revoke minters ---
        vm.prank(admin);
        tokenOwner.setMinter(minter, false);
        assertFalse(token.minters(minter));
    }

    function test_fullMigration_adminCanTransferTokenOwnership() public {
        address newOwner = address(0xCAFE);

        // --- Deploy & transfer ---
        vm.startPrank(originalOwner);
        tokenOwner = new NillionTokenOwner(token, admin);
        token.transferOwnership(address(tokenOwner));
        vm.stopPrank();

        // --- Admin can move token ownership to a new address ---
        vm.prank(admin);
        tokenOwner.transferTokenOwnership(newOwner);
        assertEq(token.owner(), newOwner);
    }

    function test_fullMigration_nonAdminCannotManage() public {
        address attacker = address(0xBAD);

        // --- Deploy & transfer ---
        vm.startPrank(originalOwner);
        tokenOwner = new NillionTokenOwner(token, admin);
        token.transferOwnership(address(tokenOwner));
        vm.stopPrank();

        // --- Non-admin cannot add minters ---
        vm.prank(attacker);
        vm.expectRevert();
        tokenOwner.setMinter(attacker, true);

        // --- Non-admin cannot transfer token ownership ---
        vm.prank(attacker);
        vm.expectRevert();
        tokenOwner.transferTokenOwnership(attacker);
    }
}
