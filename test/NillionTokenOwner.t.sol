// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../src/NillionToken.sol";
import "../src/NillionTokenOwner.sol";

contract NillionTokenOwnerTest is Test {
    NillionToken token;
    NillionTokenOwner tokenOwner;

    address admin = address(this);
    address minter = address(0xBEEF);

    function setUp() public {
        token = new NillionToken(admin);
        tokenOwner = new NillionTokenOwner(token, admin);
        // Transfer token ownership to the constrained owner
        token.transferOwnership(address(tokenOwner));
    }

    function test_cannotMintDirectly() public {
        // NillionTokenOwner has no mint function, so the owner can't bypass minters
        // Verify the constrained owner IS the token owner
        assertEq(token.owner(), address(tokenOwner));

        // The admin (this contract) can no longer mint directly on the token
        vm.expectRevert(NillionToken.NotMinter.selector);
        token.mint(admin, 1000);
    }

    function test_setMinter_onlyAdmin() public {
        tokenOwner.setMinter(minter, true);
        assertTrue(token.minters(minter));

        // Minter can mint
        vm.prank(minter);
        token.mint(minter, 1_000_000);
        assertEq(token.balanceOf(minter), 1_000_000);
    }

    function test_setMinter_rejectsNonAdmin() public {
        address nonAdmin = address(0x1234);
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonAdmin));
        tokenOwner.setMinter(minter, true);
    }

    function test_revokeMinter() public {
        tokenOwner.setMinter(minter, true);
        tokenOwner.setMinter(minter, false);
        assertFalse(token.minters(minter));

        vm.prank(minter);
        vm.expectRevert(NillionToken.NotMinter.selector);
        token.mint(minter, 1);
    }

    function test_transferTokenOwnership() public {
        address newOwner = address(0xCAFE);
        tokenOwner.transferTokenOwnership(newOwner);
        assertEq(token.owner(), newOwner);
    }

    function test_transferTokenOwnership_rejectsNonAdmin() public {
        address nonAdmin = address(0x1234);
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonAdmin));
        tokenOwner.transferTokenOwnership(nonAdmin);
    }

    function test_constrainedOwnerCannotMintOnToken() public {
        // Even though tokenOwner is the token's owner, it has no mint function
        // so there's no way to call token.mint() through it
        bytes4 mintSelector = bytes4(keccak256("mint(address,uint256)"));
        (bool success,) = address(tokenOwner).call(abi.encodeWithSelector(mintSelector, admin, 1000));
        assertFalse(success);
    }
}
