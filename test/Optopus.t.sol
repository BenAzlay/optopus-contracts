// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Optopus.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 Token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock Position Manager (Minimal Implementation)
contract MockPositionManager {
    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    function transferFrom(address, address, uint256) external {}
}

// Minimal Test Contract
contract OptopusTest is Test {
    Optopus optopus;
    MockERC20 token0;
    MockERC20 token1;
    MockPositionManager positionManager;
    address alice = address(0x1);

    function setUp() public {
        positionManager = new MockPositionManager();
        token0 = new MockERC20("Token0", "T0");
        token1 = new MockERC20("Token1", "T1");
        optopus = new Optopus(address(positionManager));
    }

    function testBasicSetup() public {
        assertEq(address(optopus.positionManager()), address(positionManager));
    }
}
