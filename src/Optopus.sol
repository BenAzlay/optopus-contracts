// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./chainlinkInterface.sol";

// Custom Option Token (ERC20)
contract OptionToken is ERC20 {
    address public immutable optopus;

    constructor(
        string memory name,
        string memory symbol,
        address _optopus
    ) ERC20(name, symbol) {
        optopus = _optopus;
    }

    modifier onlyOptopus() {
        require(msg.sender == optopus, "Only Optopus can call");
        _;
    }

    function mint(address to, uint256 amount) external onlyOptopus {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOptopus {
        _burn(from, amount);
    }
}

contract Optopus is Ownable, ReentrancyGuard, Pausable {
    INonfungiblePositionManager public immutable positionManager;
    mapping(address => AggregatorV3Interface) public priceOracles;
    mapping(address => bool) public supportedAssets;
    mapping(address => mapping(bool => OptionToken)) public optionTokens;

    struct Option {
        address owner;
        uint256 tokenId;
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint256 strikePrice;
        uint256 expiry;
        bool isCall;
        uint256 totalSupply;
        uint256 exercisedAmount;
        uint256 premium;
    }

    mapping(uint256 => Option) public options;
    uint256 public nextOptionId = 1;
    uint256 public constant EXERCISE_WINDOW = 1 hours;

    event OptionMinted(
        uint256 indexed optionId,
        address indexed owner,
        bool isCall,
        uint256 strikePrice,
        uint256 expiry
    );
    event OptionPurchased(
        uint256 indexed optionId,
        address indexed buyer,
        uint256 amount,
        uint256 totalCost
    );
    event OptionExercised(
        uint256 indexed optionId,
        address indexed user,
        uint256 amount,
        uint256 profit
    );
    event AssetsReturned(uint256 indexed optionId, address indexed owner);

    constructor(address _positionManager) Ownable(msg.sender) {
        positionManager = INonfungiblePositionManager(_positionManager);
    }

    function setPriceOracle(address asset, address oracle) external onlyOwner {
        require(oracle != address(0), "Invalid oracle address");
        (, int256 price, , uint256 timeStamp, ) = AggregatorV3Interface(oracle)
            .latestRoundData();
        require(price > 0, "Invalid oracle price");
        require(block.timestamp - timeStamp < 1 days, "Stale oracle data");
        priceOracles[asset] = AggregatorV3Interface(oracle);
        supportedAssets[asset] = true;
    }

    function mintOption(
        uint256 tokenId,
        uint256 strikePrice,
        uint256 expiry,
        bool isCall,
        address asset,
        uint256 premium,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(supportedAssets[asset], "Asset not supported");
        require(expiry > block.timestamp, "Expiry must be in future");
        require(block.timestamp <= deadline, "Transaction expired");
        require(
            positionManager.getApproved(tokenId) == address(this),
            "NFT not approved"
        );

        positionManager.transferFrom(msg.sender, address(this), tokenId);
        (
            ,
            ,
            address token0,
            address token1,
            ,
            ,
            ,
            uint128 liquidity,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);
        require(asset == token0 || asset == token1, "Invalid asset");

        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: deadline
            })
        );
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        if (address(optionTokens[asset][isCall]) == address(0)) {
            string memory name = string(
                abi.encodePacked("OPT-", asset, "-", isCall ? "CALL" : "PUT")
            );
            string memory symbol = string(
                abi.encodePacked(
                    "OPT-",
                    isCall ? "C" : "P",
                    "-",
                    uint2str(nextOptionId)
                )
            );
            optionTokens[asset][isCall] = new OptionToken(
                name,
                symbol,
                address(this)
            );
        }

        uint8 assetDecimals = ERC20(asset).decimals();
        uint256 totalSupply = (asset == token0 ? amount0 : amount1) /
            (10 ** assetDecimals);
        require(totalSupply > 0, "No liquidity for asset");

        OptionToken optionToken = optionTokens[asset][isCall];
        optionToken.mint(address(this), totalSupply * 1e18);

        Option storage newOption = options[nextOptionId];
        newOption.owner = msg.sender;
        newOption.tokenId = tokenId;
        newOption.token0 = token0;
        newOption.token1 = token1;
        newOption.amount0 = amount0;
        newOption.amount1 = amount1;
        newOption.strikePrice = strikePrice;
        newOption.expiry = expiry;
        newOption.isCall = isCall;
        newOption.totalSupply = totalSupply;
        newOption.exercisedAmount = 0;
        newOption.premium = premium;

        emit OptionMinted(
            nextOptionId,
            msg.sender,
            isCall,
            strikePrice,
            expiry
        );
        nextOptionId = nextOptionId + 1;
    }

    function buyOption(
        uint256 optionId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        Option storage option = options[optionId];
        require(option.owner != address(0), "Option does not exist");
        require(block.timestamp < option.expiry, "Option expired");
        require(
            amount <= option.totalSupply - option.exercisedAmount,
            "Insufficient tokens"
        );

        OptionToken optionToken = optionTokens[
            option.isCall ? option.token0 : option.token1
        ][option.isCall];
        address asset = option.isCall ? option.token0 : option.token1;
        uint256 totalCost = (amount * option.premium) / 1e18;

        IERC20(asset).transferFrom(msg.sender, option.owner, totalCost);
        optionToken.transfer(msg.sender, amount);

        emit OptionPurchased(optionId, msg.sender, amount, totalCost);
    }

    function exerciseOption(
        uint256 optionId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        Option storage option = options[optionId];
        require(option.owner != address(0), "Option does not exist");
        require(
            block.timestamp >= option.expiry - EXERCISE_WINDOW,
            "Not in exercise window"
        );
        require(block.timestamp <= option.expiry, "Option expired");
        require(
            option.exercisedAmount + amount <= option.totalSupply,
            "Exceeds total supply"
        );

        OptionToken optionToken = optionTokens[
            option.isCall ? option.token0 : option.token1
        ][option.isCall];
        require(
            optionToken.balanceOf(msg.sender) >= amount,
            "Insufficient tokens"
        );

        optionToken.burn(msg.sender, amount);
        address payoutAsset = option.isCall ? option.token1 : option.token0;
        uint8 assetDecimals = ERC20(
            option.isCall ? option.token0 : option.token1
        ).decimals();
        uint256 marketPrice = getAssetPrice(
            option.isCall ? option.token0 : option.token1
        );
        uint256 normalizedMarketPrice = marketPrice * (10 ** (18 - 8));
        uint256 normalizedStrikePrice = option.strikePrice *
            (10 ** (18 - assetDecimals));
        uint256 profitPerUnit = calculateProfitPerUnit(
            normalizedMarketPrice,
            normalizedStrikePrice,
            option.isCall
        );
        uint256 totalProfit = (profitPerUnit * amount) / 1e18;

        require(
            IERC20(payoutAsset).balanceOf(address(this)) >= totalProfit,
            "Insufficient funds"
        );

        option.exercisedAmount += amount;
        IERC20(payoutAsset).transfer(msg.sender, totalProfit);

        if (option.exercisedAmount == option.totalSupply) {
            delete options[optionId];
        }

        emit OptionExercised(optionId, msg.sender, amount, totalProfit);
    }

    function returnAssets(
        uint256 optionId
    ) external nonReentrant whenNotPaused {
        Option storage option = options[optionId];
        require(option.owner == msg.sender, "Not owner");
        require(block.timestamp > option.expiry, "Not expired yet");
        require(option.exercisedAmount < option.totalSupply, "Fully exercised");

        uint256 remainingSupply = option.totalSupply - option.exercisedAmount;
        uint256 totalUnits = option.totalSupply / 1e18;
        require(totalUnits > 0, "No units to return");
        uint256 remainingUnits = remainingSupply / 1e18;

        uint256 returnAmount0 = (option.amount0 * remainingUnits) / totalUnits;
        uint256 returnAmount1 = (option.amount1 * remainingUnits) / totalUnits;

        if (returnAmount0 > 0)
            IERC20(option.token0).transfer(msg.sender, returnAmount0);
        if (returnAmount1 > 0)
            IERC20(option.token1).transfer(msg.sender, returnAmount1);

        if (option.exercisedAmount == 0) {
            positionManager.transferFrom(
                address(this),
                msg.sender,
                option.tokenId
            );
        }

        emit AssetsReturned(optionId, msg.sender);
        if (remainingSupply == 0) delete options[optionId];
    }

    function getAssetPrice(address asset) internal view returns (uint256) {
        AggregatorV3Interface oracle = priceOracles[asset];
        require(address(oracle) != address(0), "No oracle for asset");
        (, int256 price, , , ) = oracle.latestRoundData();
        require(price > 0, "Invalid oracle price");
        return uint256(price);
    }

    function calculateProfitPerUnit(
        uint256 marketPrice,
        uint256 strikePrice,
        bool isCall
    ) internal pure returns (uint256) {
        if (isCall) {
            return marketPrice > strikePrice ? marketPrice - strikePrice : 0;
        } else {
            return strikePrice > marketPrice ? strikePrice - marketPrice : 0;
        }
    }

    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        while (_i != 0) {
            length--;
            bstr[length] = bytes1(uint8(48 + (_i % 10)));
            _i /= 10;
        }
        return string(bstr);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
