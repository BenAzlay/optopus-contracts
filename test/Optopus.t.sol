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

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

// Mock Uniswap V3 Position Manager
contract MockPositionManager {
    mapping(uint256 => address) public ownerOf;

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        ownerOf[tokenId] = to;
    }

    function setApproval(uint256 tokenId, address owner) external {
        ownerOf[tokenId] = owner;
    }
}

// Mock Chainlink Oracle
contract MockOracle {
    int256 public price;

    constructor(int256 _price) {
        price = _price;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, price, 0, block.timestamp, 0);
    }

    function updatePrice(int256 newPrice) external {
        price = newPrice;
    }
}

// Main Test Contract
contract OptopusTest is Test {
    Optopus optopus;
    MockERC20 token0;
    MockERC20 token1;
    MockPositionManager positionManager;
    MockOracle oracle0;
    MockOracle oracle1;

    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        // Deploy mock contracts
        positionManager = new MockPositionManager();
        token0 = new MockERC20("Token0", "T0");
        token1 = new MockERC20("Token1", "T1");
        oracle0 = new MockOracle(1000 * 1e8); // Price of token0 = $1000
        oracle1 = new MockOracle(500 * 1e8);  // Price of token1 = $500

        // Deploy Optopus contract
        optopus = new Optopus(address(positionManager));

        // Set price oracles
        optopus.setPriceOracle(address(token0), address(oracle0));
        optopus.setPriceOracle(address(token1), address(oracle1));

        // Mint and approve tokens for Alice and Bob
        token0.mint(alice, 1000 ether);
        token1.mint(bob, 1000 ether);
        vm.startPrank(alice);
        token0.approve(address(optopus), type(uint256).max);
        token1.approve(address(optopus), type(uint256).max);
        vm.stopPrank();
    }

    function testMintOption() public {
        uint256 tokenId = 1;

        // Assign NFT ownership
        positionManager.setApproval(tokenId, alice);

        vm.prank(alice);
        optopus.mintOption(
            tokenId,
            1100 * 1e8,  // Strike price = $1100
            block.timestamp + 7 days,
            true,         // Call option
            address(token0),
            10 * 1e18,    // Premium
            block.timestamp + 1 days
        );

        (address owner, , , , , , uint256 strikePrice, , bool isCall, , , ) = optopus.options(1);
        assertEq(owner, alice);
        assertEq(strikePrice, 1100 * 1e8);
        assertEq(isCall, true);
    }

    function testBuyOption() public {
        testMintOption(); // Ensure option is minted

        uint256 optionId = 1;
        uint256 amount = 1 * 1e18;
        uint256 expectedCost = 10 * 1e18;

        vm.startPrank(bob);
        token0.approve(address(optopus), expectedCost);
        optopus.buyOption(optionId, amount);
        vm.stopPrank();

        // Validate option token balance
        assertEq(token0.balanceOf(alice), expectedCost); // Alice receives the premium
    }

    function testExerciseOption() public {
        testBuyOption(); // Ensure option is purchased

        uint256 optionId = 1;
        uint256 amount = 1 * 1e18;

        // Increase token price to make the option ITM
        oracle0.updatePrice(1200 * 1e8);

        vm.startPrank(bob);
        optopus.exerciseOption(optionId, amount);
        vm.stopPrank();

        // Validate token balance
        uint256 expectedProfit = (1200 - 1100) * amount;
        assertEq(token0.balanceOf(bob), expectedProfit);
    }

    function testFailExerciseOutOfMoney() public {
        testBuyOption(); // Ensure option is purchased

        uint256 optionId = 1;
        uint256 amount = 1 * 1e18;

        // Price stays below strike price, making option OTM
        oracle0.updatePrice(1000 * 1e8);

        vm.startPrank(bob);
        optopus.exerciseOption(optionId, amount); // Should revert
        vm.stopPrank();
    }

    function testClaimExpiredAssets() public {
        testMintOption(); // Ensure option is minted

        uint256 optionId = 1;

        // Move time past expiry
        vm.warp(block.timestamp + 8 days);

        vm.prank(alice);
        optopus.returnAssets(optionId);

        // Validate ownership is returned
        (address owner, , , , , , , , , , , ) = optopus.options(1);
        assertEq(owner, address(0)); // Option should be deleted
    }
}
