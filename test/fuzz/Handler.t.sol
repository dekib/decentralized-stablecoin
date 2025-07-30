// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Test } from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import { SCEngine, AggregatorV3Interface } from "../../src/SCEngine.sol";
import { StableCoin } from "../../src/StableCoin.sol";
import { console } from "forge-std/console.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract RevertHandler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 private constant MAX_DEPOSIT_AMOUNT = 1e30; // 1 billion tokens
    uint256 private constant MAX_MINT_AMOUNT = 1e30; // 1 billion stablecoins
    uint256 private constant MIN_PRICE = 1e8; // $0.01
    uint256 private constant MAX_PRICE = 1e14; // $1,000,000

    // Deployed contracts to interact with
    SCEngine public engine;
    StableCoin public sc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;
    EnumerableSet.AddressSet private _actors;

    constructor(SCEngine _scEngine, StableCoin _sc) {
        engine = _scEngine;
        sc = _sc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    modifier trackActor() {
        _addActor(msg.sender);
        _;
    }
    
    // Add this internal function
    function _addActor(address actor) internal {
        if (!_actors.contains(actor)) {
            _actors.add(actor);
        }
    }
    
    // Add this public function
    function getActors() public view returns (address[] memory) {
        return _actors.values();
    }

    // FUNCTOINS TO INTERACT WITH

    // SCEngine //
    function mintSc(uint256 amountSc) public trackActor {
        (, uint256 collateralValueInUsd) = engine.getAccountInformation(msg.sender);
        if (collateralValueInUsd == 0) return;

        amountSc = bound(amountSc, 1, MAX_MINT_AMOUNT);
        vm.prank(msg.sender);
        engine.mintSC(amountSc);
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_AMOUNT);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        
        // Ensure user has tokens to deposit
        uint256 userBalance = collateral.balanceOf(msg.sender);
        if (userBalance < amountCollateral) {
            // Instead of minting, use available balance
            amountCollateral = userBalance;
            if (amountCollateral == 0) return;
        }

        vm.startPrank(msg.sender);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_AMOUNT);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        vm.stopPrank();
        
        depositCollateral(collateralSeed, amountCollateral);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) {
            return;
        }
        vm.prank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnSc(uint256 amountSc) public trackActor {
        // Must burn more than 0
        amountSc = bound(amountSc, 0, sc.balanceOf(msg.sender));
        if (amountSc == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        sc.approve(address(engine), amountSc);
        engine.burnSc(amountSc);
        vm.stopPrank();
    }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public trackActor {
        _addActor(userToBeLiquidated);
        uint256 userHealthFactor = engine.getHealthFactor(userToBeLiquidated);
        if (userHealthFactor >= MIN_HEALTH_FACTOR) return;
        
        (uint256 totalDebt,) = engine.getAccountInformation(userToBeLiquidated);
        if (totalDebt == 0) return;
        
        // Bound debtToCover to actual debt
        debtToCover = bound(debtToCover, 1, totalDebt);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        
        // Ensure liquidator has enough SC
        uint256 liquidatorBalance = sc.balanceOf(msg.sender);
        if (liquidatorBalance < debtToCover) {
            sc.mint(msg.sender, debtToCover - liquidatorBalance);
        }
        
        vm.startPrank(msg.sender);
        sc.approve(address(engine), debtToCover);
        engine.liquidate(address(collateral), userToBeLiquidated, debtToCover);
        vm.stopPrank();
    }

    // StableCoin //
    function transferSc(uint256 amountSc, address to) public trackActor {
        if (to == address(0)) {
            to = address(1);
        }
        _addActor(to);

        amountSc = bound(amountSc, 0, sc.balanceOf(msg.sender));
        vm.prank(msg.sender);
        sc.transfer(to, amountSc);
    }

    // Aggregator //
    function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
        newPrice = uint96(bound(newPrice, MIN_PRICE, MAX_PRICE));
        int256 intNewPrice = int256(uint256(newPrice));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(collateral)));

        priceFeed.updateAnswer(intNewPrice);
    }

    /// Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}