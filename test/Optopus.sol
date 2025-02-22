// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Optopus.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockNFT is ERC721 {
    constructor() ERC721("MockUniswapV3LP", "MULP") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract MockPriceOracle {
    int256 public price;
    constructor(int256 _price) {
        price = _price;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, 0, 0);
    }

    function updatePrice(int256 _newPrice) external {
        price = _newPrice;
    }
}

contract OptopusTest is Test {
    Optopus optopus;
    MockERC20 weth;
    MockERC20 usdc;
    MockNFT lpNFT;
    MockPriceOracle wethOracle;
    MockPriceOracle usdcOracle;

    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        weth = new MockERC20("Wrapped Ethereum", "WETH");
        usdc = new MockERC20("USD Coin", "USDC");
        lpNFT = new MockNFT();
        optopus = new Optopus(address(lpNFT));

        wethOracle = new MockPriceOracle(3000 * 10**8); // $3000
        usdcOracle = new MockPriceOracle(1 * 10**8); // $1

        optopus.setPriceOracle(address(weth), address(wethOracle));
        optopus.setPriceOracle(address(usdc), address(usdcOracle));

        lpNFT.mint(alice, 1);
        weth.mint(alice, 10 ether);
        usdc.mint(alice, 10000 * 10**6);
    }

    function testMintOption() public {
        vm.prank(alice);
        lpNFT.approve(address(optopus), 1);

        vm.prank(alice);
        optopus.lockLPAndMintOption(1, address(weth), 3100 * 10**8, block.timestamp + 7 days, true, 1 ether);

        (address user, , uint256 strikePrice, uint256 expiry, bool isCall, , bool exercised) = optopus.options(0);
        assertEq(user, alice);
        assertEq(strikePrice, 3100 * 10**8);
        assertGt(expiry, block.timestamp);
        assertEq(isCall, true);
        assertEq(exercised, false);
    }

    function testExerciseCallOptionProfitable() public {
        vm.prank(alice);
        lpNFT.approve(address(optopus), 1);
        
        vm.prank(alice);
        optopus.lockLPAndMintOption(1, address(weth), 2900 * 10**8, block.timestamp + 7 days, true, 1 ether);

        wethOracle.updatePrice(3200 * 10**8); // WETH price rises to $3200

        vm.warp(block.timestamp + 7 days - 30 minutes); // Move into exercise window

        vm.prank(alice);
        optopus.exerciseOption(0);

        (, , , , , , bool exercised) = optopus.options(0);
        assertEq(exercised, true);
    }

    function testExercisePutOptionProfitable() public {
        vm.prank(alice);
        lpNFT.approve(address(optopus), 1);

        vm.prank(alice);
        optopus.lockLPAndMintOption(1, address(usdc), 1.10 * 10**8, block.timestamp + 7 days, false, 1000 * 10**6);

        usdcOracle.updatePrice(0.95 * 10**8); // USDC drops to $0.95

        vm.warp(block.timestamp + 7 days - 30 minutes);

        vm.prank(alice);
        optopus.exerciseOption(0);

        (, , , , , , bool exercised) = optopus.options(0);
        assertEq(exercised, true);
    }

    function testFailExerciseOptionBeforeWindow() public {
        vm.prank(alice);
        lpNFT.approve(address(optopus), 1);

        vm.prank(alice);
        optopus.lockLPAndMintOption(1, address(weth), 3100 * 10**8, block.timestamp + 7 days, true, 1 ether);

        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        optopus.exerciseOption(0); // Should fail, exercise window not open
    }

    function testClaimExpiredOption() public {
        vm.prank(alice);
        lpNFT.approve(address(optopus), 1);

        vm.prank(alice);
        optopus.lockLPAndMintOption(1, address(weth), 3100 * 10**8, block.timestamp + 7 days, true, 1 ether);

        vm.warp(block.timestamp + 8 days); // Move past expiry

        vm.prank(alice);
        optopus.claimExpiredAssets(0);

        (, , , , , , bool exercised) = optopus.options(0);
        assertEq(exercised, false);
    }
}
