//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
/**
 * @title DSCEngine
 * @author Rusty Metalhead
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == 1$ peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC
 *
 * Our DSC system should always be overcollateralized. At no point, should the value of all collateral <= the $backed value of all the DSC
 *
 * @notice This contract is the core of DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is loosely based on the MakerDao DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    ////////////
    // ERRORS //
    ////////////
    error DSCEngine__AmountMustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);

    /////////////////////
    // STATE VARIABLES //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //50/100 = 1/2 => double collateral needed. 200% overcollateralized.
    uint256 private constant MINIMUM_HEALTH_FACTOR = 1;
    mapping(address token => address priceFeed) private s_tokenToPriceFeed;
    DecentralizedStableCoin private i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_userToCollateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_userToDscMinted;
    address[] private s_collateralTokenAddress;

    ////////////
    // EVENTS //
    ////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    ///////////////
    // MODIFIERS //
    ///////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) revert DSCEngine__AmountMustBeMoreThanZero();
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_tokenToPriceFeed[token] == address(0)) revert DSCEngine__TokenNotAllowed();
        _;
    }
    ///////////////
    // FUNCTIONS //
    ///////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_tokenToPriceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokenAddress.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // EXTERNAL FUNCTIONS //
    ////////////////////////
    function depositCollateralAndMintDsc() external {}

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to be deposited as collateral
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_userToCollateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool isSuccess = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!isSuccess) revert DSCEngine__TransferFailed();
    }

    function redeemCollateralForDsc() external {}
    function redeemCollateral() external {}

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_userToDscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool isMinted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!isMinted) revert DSCEngine__MintFailed();
    }

    function burnDsc() external {}
    function liquidate() external {}
    function getHealthFactor() external {}

    //////////////////////////////////
    // PRIVATE & INTERNAL VIEW FUNCTIONS //
    //////////////////////////////////
    //1. CHeck if they have enough collateral
    //2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MINIMUM_HEALTH_FACTOR) revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }

    /**
     *
     * Returns how close a user is to liquidation
     * If a user goes below 1 (or other defined ratio), the user can get liquidated.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_userToDscMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    //////////////////////////////////
    // PUBLIC & EXTERNAL VIEW FUNCTIONS //
    //////////////////////////////////
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokenAddress.length; i++) {
            address token = s_collateralTokenAddress[i];
            uint256 amount = s_userToCollateralDeposited[user][token]; //This is amount of collateral. We need to convert it to usd
            //TODO: check if amount != 0
            totalCollateralValueInUsd += getTokenUsdValue(token, amount);
        }
    }

    function getTokenUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }
} //https://youtu.be/wUjYK5gwNZs?list=PL4Rj_WH6yLgWe7TxankiqkrkVKXIwOP42&t=6445
