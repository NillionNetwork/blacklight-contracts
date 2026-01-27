// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../src/NillionToken.sol";

contract NillionTokenTest is Test {
    NillionToken token;

    address owner = address(this);
    address minter = address(0xBEEF);

    function setUp() public {
        token = new NillionToken(owner);
    }

    function test_setMinter_onlyOwner_and_allowsMint() public {
        address nonOwner = address(0x1234);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        token.setMinter(minter, true);

        token.setMinter(minter, true);
        assertTrue(token.minters(minter));

        vm.prank(minter);
        token.mint(minter, 1_000_000);
        assertEq(token.balanceOf(minter), 1_000_000);
    }

    function test_setMinter_rejectsZeroAddress() public {
        vm.expectRevert(NillionToken.ZeroAddress.selector);
        token.setMinter(address(0), true);
    }
}
