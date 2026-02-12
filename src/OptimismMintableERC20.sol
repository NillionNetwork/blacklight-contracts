// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IOptimismMintableERC20 is IERC165 {
    function bridge() external view returns (address);
    function remoteToken() external view returns (address);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @notice OP-style L2 bridge-mintable ERC20.
/// @dev The L2 StandardBridge is the sole minter/burner.
contract OptimismMintableERC20 is ERC20, IOptimismMintableERC20 {
    address public immutable l2Bridge;
    address public immutable l1Token;

    uint8 private immutable _decimals;

    error OnlyBridge();
    error ZeroAddress();

    constructor(address _l2Bridge, address _l1Token, string memory _name, string memory _symbol, uint8 decimals_)
        ERC20(_name, _symbol)
    {
        if (_l2Bridge == address(0) || _l1Token == address(0)) revert ZeroAddress();
        l2Bridge = _l2Bridge;
        l1Token = _l1Token;
        _decimals = decimals_;
    }

    modifier onlyBridge() {
        if (msg.sender != l2Bridge) revert OnlyBridge();
        _;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function bridge() external view returns (address) {
        return l2Bridge;
    }

    function remoteToken() external view returns (address) {
        return l1Token;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IOptimismMintableERC20).interfaceId;
    }

    function mint(address to, uint256 amount) external override onlyBridge {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override onlyBridge {
        _burn(from, amount);
    }
}
