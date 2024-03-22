//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

    /////////////////////
    // STATE VARIABLES //
    /////////////////////
    mapping(address token => address priceFeed) private s_tokenToPriceFeed;
    DecentralizedStableCoin private i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_userToCollateralDeposited;

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

    function mintDsc() external {}
    function burnDsc() external {}
    function liquidate() external {}
    function getHealthFactor() external {}
} //https://youtu.be/wUjYK5gwNZs?list=PL4Rj_WH6yLgWe7TxankiqkrkVKXIwOP42&t=5027
