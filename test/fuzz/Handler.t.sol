//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract Handler is Test {
    uint96 MAX_AMOUNT_DEPOSITED = type(uint96).max;
    DecentralizedStableCoin public dsc;
    DSCEngine public dsce;
    ERC20Mock public weth;
    ERC20Mock public wbtc;
    address[] public s_usersWithCollateralDeposited;

    constructor(DecentralizedStableCoin _dsc, DSCEngine _dsce) {
        dsc = _dsc;
        dsce = _dsce;

        address[] memory collateralTokens = dsce.getCollateralTokenAddress();
        weth = ERC20Mock(address(collateralTokens[0]));
        wbtc = ERC20Mock(address(collateralTokens[1]));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountDeposited) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountDeposited = bound(amountDeposited, 1, MAX_AMOUNT_DEPOSITED);

        vm.prank(msg.sender);
        collateral.mint(msg.sender, amountDeposited);
        collateral.approve(address(dsce), amountDeposited);
        dsce.depositCollateral(address(collateral), amountDeposited);
        vm.stopPrank();
        s_usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) return;
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (s_usersWithCollateralDeposited.length == 0) return;

        address sender = s_usersWithCollateralDeposited[addressSeed % s_usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) return;
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) return;

        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
    }
    // Helper Functions

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }

        return wbtc;
    }
}
