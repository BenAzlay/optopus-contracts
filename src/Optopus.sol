// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Standard ERC20 and ERC721 interfaces from OpenZeppelin
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// Interface for Uniswap V3 position manager (for transferring and modifying LP positions)
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

// Chainlink price feed interface
import "./chainlinkInterface.sol";

/**
 * @title OptionToken
 * @dev A simple ERC20 token representing an "option token" for a specific (asset, isCall) pair.
 *      Only the main Optopus contract can mint or burn.
 */
contract OptionToken is ERC20 {
    // The address of the main Optopus contract that controls minting/burning.
    address public immutable optopus;

    /**
     * @dev Constructor sets up token name, symbol, and the controlling Optopus address.
     * @param name The ERC20 name of the option token.
     * @param symbol The ERC20 symbol of the option token.
     * @param _optopus The address of the main Optopus contract.
     */
    constructor(
        string memory name,
        string memory symbol,
        address _optopus
    ) ERC20(name, symbol) {
        optopus = _optopus;
    }

    /**
     * @dev Throws if called by any account other than Optopus.
     */
    modifier onlyOptopus() {
        require(msg.sender == optopus, "Only Optopus can call");
        _;
    }

    /**
     * @dev Mints option tokens. Can only be called by the Optopus contract.
     * @param to The recipient of the newly minted tokens.
     * @param amount The number of tokens to mint.
     */
    function mint(address to, uint256 amount) external onlyOptopus {
        _mint(to, amount);
    }

    /**
     * @dev Burns option tokens. Can only be called by the Optopus contract.
     * @param from The address whose tokens will be burned.
     * @param amount The number of tokens to burn.
     */
    function burn(address from, uint256 amount) external onlyOptopus {
        _burn(from, amount);
    }
}

/**
 * @title Optopus
 * @dev Main contract that manages creating and exercising call/put options backed by
 *      Uniswap V3 LP positions. Uses Chainlink oracles for price data.
 */
contract Optopus is Ownable, ReentrancyGuard, Pausable {
    // Reference to the Uniswap V3 Nonfungible Position Manager
    INonfungiblePositionManager public immutable positionManager;

    // Maps an asset to its Chainlink price feed
    mapping(address => AggregatorV3Interface) public priceOracles;
    // Tracks whether a given asset is supported
    mapping(address => bool) public supportedAssets;

    /**
     * @dev optionTokens[asset][isCall] => OptionToken contract
     *      Each (asset, isCall) pair has its own OptionToken ERC20 instance.
     */
    mapping(address => mapping(bool => OptionToken)) public optionTokens;

    /**
     * @dev Represents the data for a single option created by a user.
     * @param owner The original writer/creator of the option
     * @param tokenId The Uniswap V3 LP NFT ID used as collateral
     * @param asset The chosen asset from the LP pair on which the option is based
     * @param token0 token0 from the LP position
     * @param token1 token1 from the LP position
     * @param amount0 The total amount of token0 removed from the LP
     * @param amount1 The total amount of token1 removed from the LP
     * @param strikePrice The strike price for the option (subject to decimal conventions)
     * @param expiry The Unix timestamp when the option expires
     * @param isCall True if it's a call, false if it's a put
     * @param totalSupply The total number of option tokens minted
     * @param exercisedAmount How many option tokens have been exercised
     * @param premium The cost (in `asset`) per 1e18 units of option tokens
     */
    struct Option {
        address owner;
        uint256 tokenId;
        address asset;
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

    // Maps optionId => Option details
    mapping(uint256 => Option) public options;

    // Tracks the next unique ID to assign to a newly minted option
    uint256 public nextOptionId = 1;

    // The exercise window length: an option is exercisable only in the last 1 hour before expiry
    uint256 public constant EXERCISE_WINDOW = 1 hours;

    // Events
    event OptionMinted(
        uint256 indexed optionId,
        address indexed owner,
        uint256 tokenId,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 strikePrice,
        uint256 expiry,
        bool isCall,
        uint256 totalSupply,
        uint256 premium
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

    /**
     * @dev Constructor initializes the position manager reference and sets the owner.
     * @param _positionManager The address of the Uniswap V3 NonfungiblePositionManager.
     */
    constructor(address _positionManager) Ownable(msg.sender) {
        positionManager = INonfungiblePositionManager(_positionManager);
    }

    /**
     * @dev Sets the Chainlink price oracle for a given asset, marking the asset as supported.
     * @param asset The address of the ERC20 token.
     * @param oracle The address of the Chainlink AggregatorV3Interface oracle.
     */
    function setPriceOracle(address asset, address oracle) external onlyOwner {
        require(oracle != address(0), "Invalid oracle address");
        // Fetch the latest round data to verify it's a valid oracle
        (, int256 price, , uint256 timeStamp, ) = AggregatorV3Interface(oracle)
            .latestRoundData();
        require(price > 0, "Invalid oracle price");
        require(block.timestamp - timeStamp < 1 days, "Stale oracle data");

        // Register the oracle and mark the asset as supported
        priceOracles[asset] = AggregatorV3Interface(oracle);
        supportedAssets[asset] = true;
    }

    /**
     * @dev Creates (mints) a new option by locking up a Uniswap V3 LP NFT as collateral.
     *      Removes all liquidity from the position, storing token0/token1 in this contract.
     *      Mints ERC20 "option tokens" that can be sold to buyers.
     *
     * @param tokenId The Uniswap V3 position NFT ID to lock as collateral.
     * @param strikePrice The strike price for this option.
     * @param expiry The Unix timestamp at which this option will expire.
     * @param isCall True for a call option, false for a put.
     * @param asset Which token in the LP pair is used as the "underlying" for strike calculations.
     * @param premium Cost (in `asset`) per 1e18 units of the option token.
     * @param deadline The deadline for the liquidity removal (Uniswap safety).
     */
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
        // Ensure the contract can handle this NFT
        require(
            positionManager.getApproved(tokenId) == address(this),
            "NFT not approved"
        );

        // Transfer the LP NFT to the contract
        positionManager.transferFrom(msg.sender, address(this), tokenId);

        // Fetch details of the position, including token0, token1, and liquidity
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

        // The chosen asset must be one of the LP tokens
        require(asset == token0 || asset == token1, "Invalid asset");

        // Remove all liquidity to get actual token balances in the contract
        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: deadline
            })
        );

        // Collect any accrued fees in the position
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // If there's no OptionToken contract yet for (asset, isCall), deploy one
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

        // The total supply of option tokens equals the quantity of the chosen asset
        uint256 totalSupply = (asset == token0 ? amount0 : amount1);
        require(totalSupply > 0, "No liquidity for asset");

        // Mint that number of ERC20 "option tokens" to the contract itself
        OptionToken optionToken = optionTokens[asset][isCall];
        optionToken.mint(address(this), totalSupply);

        // Create a new Option struct and store it
        Option storage newOption = options[nextOptionId];
        newOption.owner = msg.sender;
        newOption.tokenId = tokenId;
        newOption.asset = asset;
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
            tokenId,
            token0,
            token1,
            amount0,
            amount1,
            strikePrice,
            expiry,
            isCall,
            totalSupply,
            premium
        );

        // Increment nextOptionId for the next new option
        nextOptionId = nextOptionId + 1;
    }

    /**
     * @dev Allows a buyer to purchase some quantity of the option tokens (ERC20)
     *      by paying the seller a premium in `option.asset`.
     * @param optionId The ID of the option being purchased.
     * @param amount How many option tokens to buy.
     */
    function buyOption(
        uint256 optionId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        Option storage option = options[optionId];
        require(option.owner != address(0), "Option does not exist");
        // Buying is only allowed before expiry
        require(block.timestamp < option.expiry, "Option expired");

        // There must be enough unexercised tokens left
        require(
            amount <= option.totalSupply - option.exercisedAmount,
            "Insufficient tokens"
        );

        // Retrieve the specific ERC20 option token
        OptionToken optionToken = optionTokens[option.asset][option.isCall];

        // Calculate total premium cost: (amount * premium) / 1e18
        uint256 totalCost = (amount * option.premium) / 1e18;

        // Transfer premium from buyer to the option creator
        IERC20(option.asset).transferFrom(msg.sender, option.owner, totalCost);

        // Transfer the purchased option tokens from the contract to the buyer
        optionToken.transfer(msg.sender, amount);

        emit OptionPurchased(optionId, msg.sender, amount, totalCost);
    }

    /**
     * @dev Exercises some quantity of the option tokens, receiving a payout if it's in-the-money.
     *      Only valid in the last hour before expiry (European style).
     * @param optionId The ID of the option to exercise.
     * @param amount How many option tokens to exercise.
     */
    function exerciseOption(
        uint256 optionId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        Option storage option = options[optionId];
        require(option.owner != address(0), "Option does not exist");

        // European exercise window: [expiry - EXERCISE_WINDOW, expiry]
        require(
            block.timestamp >= option.expiry - EXERCISE_WINDOW,
            "Not in exercise window"
        );
        require(block.timestamp <= option.expiry, "Option expired");

        // Must not exceed total supply
        require(
            option.exercisedAmount + amount <= option.totalSupply,
            "Exceeds total supply"
        );

        // Ensure the caller owns enough option tokens to exercise
        OptionToken optionToken = optionTokens[option.asset][option.isCall];
        require(
            optionToken.balanceOf(msg.sender) >= amount,
            "Insufficient tokens"
        );

        // Burn the user's option tokens
        optionToken.burn(msg.sender, amount);

        // Calculate the profit in "asset" terms
        uint8 assetDecimals = ERC20(option.asset).decimals();
        uint256 marketPrice = getAssetPrice(option.asset);

        // Example scaling: assumes Chainlink feed has 8 decimals, token might have different decimals
        uint256 normalizedMarketPrice = marketPrice * (10 ** (18 - 8));
        uint256 normalizedStrikePrice = option.strikePrice *
            (10 ** (18 - assetDecimals));

        // Profit per unit based on call or put
        uint256 profitPerUnit = calculateProfitPerUnit(
            normalizedMarketPrice,
            normalizedStrikePrice,
            option.isCall
        );

        // Total profit is profitPerUnit * quantity exercised
        uint256 totalProfit = (profitPerUnit * amount) / 1e18;

        // Ensure the contract has enough funds to pay out
        require(
            IERC20(option.asset).balanceOf(address(this)) >= totalProfit,
            "Insufficient funds"
        );

        // Update how much has been exercised
        option.exercisedAmount += amount;

        // Pay the user their profit
        IERC20(option.asset).transfer(msg.sender, totalProfit);

        // If everything is exercised, we can delete the option to save gas
        if (option.exercisedAmount == option.totalSupply) {
            delete options[optionId];
        }

        emit OptionExercised(optionId, msg.sender, amount, totalProfit);
    }

    /**
     * @dev Returns any unexercised collateral to the option writer after expiry.
     *      If the option was never exercised, it also returns the original LP NFT.
     * @param optionId The ID of the option whose assets to return.
     */
    function returnAssets(
        uint256 optionId
    ) external nonReentrant whenNotPaused {
        Option storage option = options[optionId];
        require(option.owner == msg.sender, "Not owner");
        require(block.timestamp > option.expiry, "Not expired yet");
        require(option.exercisedAmount < option.totalSupply, "Fully exercised");

        // Convert remaining supply to a fraction of the total
        uint256 remainingSupply = option.totalSupply - option.exercisedAmount;
        uint256 totalUnits = option.totalSupply / 1e18;
        require(totalUnits > 0, "No units to return");
        uint256 remainingUnits = remainingSupply / 1e18;

        // Calculate how much of token0 and token1 are left
        uint256 returnAmount0 = (option.amount0 * remainingUnits) / totalUnits;
        uint256 returnAmount1 = (option.amount1 * remainingUnits) / totalUnits;

        // Transfer leftover token0 and token1 back to the owner
        if (returnAmount0 > 0)
            IERC20(option.token0).transfer(msg.sender, returnAmount0);
        if (returnAmount1 > 0)
            IERC20(option.token1).transfer(msg.sender, returnAmount1);

        // If nothing was exercised, we can also return the original LP NFT
        if (option.exercisedAmount == 0) {
            positionManager.transferFrom(
                address(this),
                msg.sender,
                option.tokenId
            );
        }

        emit AssetsReturned(optionId, msg.sender);

        // If all leftover supply is now returned, delete the option from storage
        if (remainingSupply == 0) delete options[optionId];
    }

    /**
     * @dev Fetches the latest price from the stored Chainlink aggregator for a specific asset.
     * @param asset The ERC20 token address for which we're getting the price.
     */
    function getAssetPrice(address asset) internal view returns (uint256) {
        AggregatorV3Interface oracle = priceOracles[asset];
        require(address(oracle) != address(0), "No oracle for asset");
        (, int256 price, , , ) = oracle.latestRoundData();
        require(price > 0, "Invalid oracle price");
        return uint256(price);
    }

    /**
     * @dev Determines the profit per unit for a call or put based on the difference
     *      between marketPrice and strikePrice.
     * @param marketPrice The current normalized market price.
     * @param strikePrice The normalized strike price.
     * @param isCall True if it's a call; false if it's a put.
     */
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

    /**
     * @dev Utility function to convert a uint into its decimal string representation.
     * @param _i The uint to convert.
     */
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

    /**
     * @dev Implements the ERC721 receiver interface so the contract can hold LP NFTs.
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
