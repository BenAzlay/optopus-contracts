// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Optopus is Ownable {
    struct Option {
        address user;
        address asset;
        uint256 strikePrice;
        uint256 expiry;
        bool isCall; // true = call, false = put
        uint256 amount;
        bool exercised;
    }

    IERC721 public uniswapV3NFT;
    mapping(uint256 => Option) public options;
    mapping(address => AggregatorV3Interface) public priceOracles; // Asset -> Oracle
    mapping(address => bool) public supportedAssets;
    uint256 public optionCounter;
    uint256 public constant EXERCISE_WINDOW = 1 hours;

    event OptionMinted(uint256 indexed optionId, address indexed user, bool isCall, uint256 strikePrice, uint256 expiry);
    event OptionExercised(uint256 indexed optionId, address indexed user, uint256 profit);
    event OptionExpired(uint256 indexed optionId, address indexed user);
    event UniswapNFTLocked(uint256 indexed tokenId, address indexed user);

    constructor(address _uniswapV3NFT) {
        uniswapV3NFT = IERC721(_uniswapV3NFT);
    }

    function setPriceOracle(address asset, address oracle) external onlyOwner {
        priceOracles[asset] = AggregatorV3Interface(oracle);
        supportedAssets[asset] = true;
    }

    function lockLPAndMintOption(
        uint256 tokenId,
        address asset,
        uint256 strikePrice,
        uint256 expiry,
        bool isCall,
        uint256 amount
    ) external {
        require(supportedAssets[asset], "Asset not supported");
        require(expiry > block.timestamp, "Expiry must be in the future");

        uniswapV3NFT.transferFrom(msg.sender, address(this), tokenId);
        uint256 optionId = optionCounter++;

        options[optionId] = Option({
            user: msg.sender,
            asset: asset,
            strikePrice: strikePrice,
            expiry: expiry,
            isCall: isCall,
            amount: amount,
            exercised: false
        });

        emit UniswapNFTLocked(tokenId, msg.sender);
        emit OptionMinted(optionId, msg.sender, isCall, strikePrice, expiry);
    }

    function exerciseOption(uint256 optionId) external {
        Option storage opt = options[optionId];
        require(opt.user == msg.sender, "Not option owner");
        require(block.timestamp >= opt.expiry - EXERCISE_WINDOW, "Exercise window not open");
        require(block.timestamp <= opt.expiry, "Option expired");
        require(!opt.exercised, "Already exercised");

        uint256 marketPrice = _getAssetPrice(opt.asset);
        uint256 profit = 0;

        if (opt.isCall) {
            require(marketPrice > opt.strikePrice, "Call option out of the money");
            profit = (marketPrice - opt.strikePrice) * opt.amount;
        } else {
            require(marketPrice < opt.strikePrice, "Put option out of the money");
            profit = (opt.strikePrice - marketPrice) * opt.amount;
        }

        opt.exercised = true;
        IERC20(opt.asset).transfer(opt.user, profit);
        emit OptionExercised(optionId, msg.sender, profit);
    }

    function claimExpiredAssets(uint256 optionId) external {
        Option storage opt = options[optionId];
        require(opt.user == msg.sender, "Not option owner");
        require(block.timestamp > opt.expiry, "Option not expired");
        require(!opt.exercised, "Already exercised");

        // Return the original LP NFT if option expired unexercised
        uniswapV3NFT.transferFrom(address(this), msg.sender, optionId);
        emit OptionExpired(optionId, msg.sender);
    }

    function _getAssetPrice(address asset) internal view returns (uint256) {
        AggregatorV3Interface oracle = priceOracles[asset];
        (, int256 price, , , ) = oracle.latestRoundData();
        require(price > 0, "Invalid oracle price");
        return uint256(price);
    }
}
