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
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////
    // STATE VARIABLES //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //50/100 = 1/2 => double collateral needed. 200% overcollateralized.
    uint256 private constant MINIMUM_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDATION_BONUS = 10;
    mapping(address token => address priceFeed) private s_tokenToPriceFeed;
    DecentralizedStableCoin private i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_userToCollateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_userToDscMinted;
    address[] private s_collateralTokenAddress;

    ////////////
    // EVENTS //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

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
    /**
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to be deposited as collateral
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice deposites collateral and mints DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) public {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to be deposited as collateral
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_userToCollateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool isSuccess = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!isSuccess) revert DSCEngine__TransferFailed();
    }
    /**
     * @param tokenCollateralAddress The address of the token to be deposited as collateral
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDsc The amount of DSC to burn
     * This function burns DSC and redeems collateral in one transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDsc)
        external
    {
        burnDsc(amountDsc);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor.
    }

    /**
     * @notice healthFactor should be greater than 1 AFTER collateral is redeemed
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_userToDscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool isMinted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!isMinted) revert DSCEngine__MintFailed();
    }

    function burnDsc(uint256 amountDsc) public moreThanZero(amountDsc) {
        _burnDsc(amountDsc, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //I don't think so this would ever break
    }

    /**
     * If someone is undercollateralized, we will pay to liquidate them
     * E.g. 75$ ETH backing 50$ DSC -> undercollateralized
     * Therefore, liquidator takes 75$ worth ETH and burns (pays off debt) 50$ DSC
     *
     * @param collateral The ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor should be less than MINIMUM_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the user's health factor
     * @notice Follows CEI
     * @notice you can partially liquidate a user.
     * @notice you will get a liquidation bonus for taking the user's funds
     * @notice This function assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidators.
     * e.g. If price of collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 userStartingHealthFactor = _healthFactor(user);
        if (userStartingHealthFactor >= MINIMUM_HEALTH_FACTOR) revert DSCEngine__HealthFactorOk();

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //give them a 10% bonus => 110$ WETH for 100$ DSC
        //Sweep the extra amount to treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 userEndingHealthFactor = _healthFactor(user);
        if (userEndingHealthFactor <= userStartingHealthFactor) revert DSCEngine__HealthFactorNotImproved();

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external {}

    //////////////////////////////////
    // PRIVATE & INTERNAL VIEW FUNCTIONS //
    //////////////////////////////////
    //1. Check if they have enough collateral
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

    /**
     *
     * @dev low-level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_userToCollateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool isSuccess = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!isSuccess) revert DSCEngine__TransferFailed();
    }

    /**
     *
     * @dev low-level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDsc(uint256 amountDsc, address onBehalfOf, address dscFrom) private {
        s_userToDscMinted[onBehalfOf] -= amountDsc;
        //event?
        bool isSuccess = i_dsc.transferFrom(dscFrom, address(this), amountDsc);
        if (!isSuccess) revert DSCEngine__TransferFailed();

        i_dsc.burn(amountDsc);
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

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (usdAmountInWei * PRECISION / uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
}
