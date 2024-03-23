//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address wethUsdPriceFeed;
    address weth;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (wethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();
    }
    ////////////////////
    // PriceFeed Test //
    ////////////////////

    function testGetTokenUsdValue() public view {
        uint256 amount = 15e18;
        uint256 expectedUsd = 30_000e18;
        uint256 actualUsd = dsce.getTokenUsdValue(weth, amount);

        assertEq(expectedUsd, actualUsd);
    }

    /////////////////////////////
    // Deposit Collateral Test //
    /////////////////////////////
}
