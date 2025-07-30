// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeploySC} from "../../script/DeploySC.s.sol";
import {StableCoin} from "../../src/StableCoin.sol";
import {SCEngine} from "../../src/SCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {RevertHandler} from "./Handler.t.sol";

contract InvariantTest is StdInvariant, Test {
    DeploySC deployer;
    SCEngine engine;
    StableCoin sc;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    RevertHandler public handler;

    function setUp() external {
        deployer = new DeploySC();
        (sc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        handler = new RevertHandler(engine, sc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotal() public view {
        uint256 totalSupply = sc.totalSupply();
        uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethInUsd = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcInUsd = engine.getUsdValue(wbtc, totalWbtcDeposited);

        assert(wethInUsd + wbtcInUsd >= totalSupply);

    }

    function invariant_protocolMustBeOvercollateralized() public view {
        uint256 totalSupply = sc.totalSupply();
        uint256 totalCollateralValue;
        
        address[] memory collateralTokens = engine.getCollateralTokens();
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 balance = ERC20Mock(token).balanceOf(address(engine));
            uint256 usdValue = engine.getUsdValue(token, balance);
            totalCollateralValue += usdValue;
        }
        
        // Apply liquidation threshold (75%)
        uint256 adjustedCollateralValue = totalCollateralValue * 75 / 100;
        
        // Handle division precision
        uint256 scaledCollateral = adjustedCollateralValue * 1e18;
        uint256 scaledDebt = totalSupply;
        
        assertGe(
            scaledCollateral,
            scaledDebt,
            "Protocol undercollateralized!"
        );
    }

}
