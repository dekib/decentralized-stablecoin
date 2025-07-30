// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploySC} from "../../script/DeploySC.s.sol";
import {StableCoin} from "../../src/StableCoin.sol";
import {SCEngine} from "../../src/SCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockFailedMintSC} from "../mocks/MockFailedMintSC.sol";
import {MockMoreDebtSC} from "../mocks/MockMoreDebtSC.sol";
import {MockTransferFailed} from "../mocks/MockTransferFailed.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract SCEngineTest is Test {
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    event SurplusDeposited(address indexed user, address indexed token, uint256 amount);

    DeploySC deployer;
    StableCoin sc;
    SCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");
    address public admin = makeAddr("admin");

    uint256 public constant AMOUNT_COLLATERAL = 1 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 1000e18;
    uint256 public constant COLLATERAL_TO_COVER = 3 ether;
    uint256 public constant ONE_ETHER_COLLATERAL_TO_COVER = 1 ether;
    uint256 public constant LIQUIDATION_BONUS = 10;
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant HOUR_IN_SEC = 3600;

    function setUp() public {
        deployer = new DeploySC();
        (sc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        vm.warp(block.timestamp + HOUR_IN_SEC);

        ERC20Mock(weth).mint(admin, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(user, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(liquidator, COLLATERAL_TO_COVER);
        // ERC20Mock(wbtc).mint(user, STARTING_ERC20_BALANCE);
    }

    // Constructor Test //

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(SCEngine.SCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);

        new SCEngine(tokenAddresses, priceFeedAddresses, address(sc));
    }

    // Price Test //
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testRevertStaleUsdValue() public {
        uint256 ethAmount = 15e18;
        vm.warp(HOUR_IN_SEC + 2);
        vm.expectRevert(SCEngine.SCEngine__StalePrice.selector);
        engine.getUsdValue(weth, ethAmount);
    }

    function testRevertZeroPriceUsdValue() public {
        uint256 ethAmount = 15e18;
        int256 ethUsdUpdatedZeroPrice = 0;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedZeroPrice);
        vm.expectRevert(SCEngine.SCEngine__PriceIsZero.selector);
        engine.getUsdValue(weth, ethAmount);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 200 ether;
        // test chainlink value $2000 = 1 ether
        uint256 expectedWeth = 0.1 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    // Deposit Colateral //

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(SCEngine.SCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnaprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", user, AMOUNT_COLLATERAL);
        vm.startPrank(user);

        vm.expectRevert(SCEngine.SCEngine__TokenNotAllowed.selector);

        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // deposit wETH
    modifier depositCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    // deposit wBTC
    modifier depositBtcCollateral() {
        vm.startPrank(user);
        ERC20Mock(wbtc).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintSc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function approveAndDeposit(address token, uint256 amountCollateral, uint amountSCToMint) internal {
        vm.startPrank(user);
        ERC20Mock(token).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintSC(token, amountCollateral, amountSCToMint);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndAccountInfo() public depositCollateral {
        (uint256 totalScMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(user);

        uint256 expectedTotalScMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalScMinted, expectedTotalScMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testGetAccountCollateralValue() public depositCollateral {
        uint256 expectedTotal = 2000 * 1e18;
        uint256 expectedTotalUserCollateralAmount = engine.getUserCollateralDepositedInUsd(user);

        assertEq(expectedTotalUserCollateralAmount, expectedTotal);
    }

    function testCollateralDepositedEvent() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralDeposited(user, weth, AMOUNT_COLLATERAL);

        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCollateralDepositedBalance() public depositCollateral {
        uint256 expectedUserBalance = STARTING_ERC20_BALANCE - AMOUNT_COLLATERAL;
        uint256 scBalance = ERC20Mock(weth).balanceOf(address(engine));
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);

        assertEq(expectedUserBalance, userBalance);
        assertEq(AMOUNT_COLLATERAL, scBalance);
    }

    function testMintSC() public depositCollateral {
        vm.startPrank(user);
        engine.mintSC(AMOUNT_COLLATERAL);

        (uint256 totalScMinted,) = engine.getAccountInformation(user);
        uint256 totalTokens = sc.totalSupply();
        uint256 userBalance = sc.balanceOf(user);

        assertEq(AMOUNT_COLLATERAL, totalScMinted);
        assertEq(AMOUNT_COLLATERAL, totalTokens);
        assertEq(AMOUNT_COLLATERAL, userBalance);
        vm.stopPrank();
    }

    function testRevertMintSCIfAmountIsZero() public depositCollateral {
        vm.startPrank(user);
        vm.expectRevert(SCEngine.SCEngine__NeedsMoreThanZero.selector);
        engine.mintSC(0);

        vm.stopPrank();
    }

    function testRevertsIfMintFails() public {
        MockFailedMintSC mockSc = new MockFailedMintSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        SCEngine mockSce = new SCEngine(tokenAddresses, priceFeedAddresses, address(mockSc));
        mockSc.transferOwnership(address(mockSce));

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockSce), AMOUNT_COLLATERAL);

        vm.expectRevert(SCEngine.SCEngine__MintFailed.selector);
        mockSce.depositCollateralAndMintSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    //  burn test //

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);

        try engine.burnSc(1) {
            assertFalse(true, "Expected revert, but call succeeded"); 
        } catch Error(string memory reason) {
            emit log_string(reason);
            assertEq(reason, "arithmetic underflow or overflow");
        } catch (bytes memory lowLevelData) {
            emit log_bytes(lowLevelData);
        }
    }

    function testBurn() public depositedCollateralAndMintSc {
        vm.startPrank(user);

        sc.approve(address(engine), AMOUNT_TO_MINT);
        engine.burnSc(AMOUNT_TO_MINT);

        uint256 userBalance = sc.balanceOf(user);
        assertEq(userBalance, 0);
        vm.stopPrank();
    }

    function testBurnAmountZero() public depositedCollateralAndMintSc {
        vm.startPrank(user);

        vm.expectRevert(SCEngine.SCEngine__NeedsMoreThanZero.selector);
        engine.burnSc(0);

        vm.stopPrank();
    }

    // withdraw test //

    function testRedeemCollateralEmit() public depositCollateral {
        vm.startPrank(user);
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(user, user, weth, AMOUNT_COLLATERAL);

        uint256 collateralAmount = engine.getUserCollateralAmount(user, address(weth));
        uint256 userBalancePre = ERC20Mock(weth).balanceOf(user);

        assertEq(collateralAmount, AMOUNT_COLLATERAL);
        assertEq(userBalancePre, STARTING_ERC20_BALANCE - AMOUNT_COLLATERAL);

        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        uint256 expectedTotalUserCollateralAmount = engine.getUserCollateralDepositedInUsd(user);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);

        assertEq(STARTING_ERC20_BALANCE, userBalance);
        assertEq(expectedTotalUserCollateralAmount, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralAmountZero() public depositedCollateralAndMintSc {
        vm.startPrank(user);

        vm.expectRevert(SCEngine.SCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);

        vm.stopPrank();
    }

    function newMockScTransferFails() public returns (MockTransferFailed, SCEngine) {
        address owner = msg.sender;
        vm.startPrank(owner);
        MockTransferFailed mockSc = new MockTransferFailed();

        tokenAddresses = [address(mockSc)];
        priceFeedAddresses = [ethUsdPriceFeed];

        SCEngine mockEngine = new SCEngine(tokenAddresses, priceFeedAddresses, address(mockSc));
        mockSc.mint(user, AMOUNT_COLLATERAL);

        mockSc.transferOwnership(address(mockEngine));
        vm.stopPrank();

        return (mockSc, mockEngine);
    }

    function testTransferFails() public {
        (MockTransferFailed mockSc, SCEngine mockEngine) = newMockScTransferFails();

        vm.startPrank(user);
        ERC20Mock(address(mockSc)).approve(address(mockEngine), AMOUNT_COLLATERAL);

        mockEngine.depositCollateral(address(mockSc), AMOUNT_COLLATERAL);
        vm.expectRevert(SCEngine.SCEngine__TransferFailed.selector);

        mockEngine.redeemCollateral(address(mockSc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralAndBurn() public depositedCollateralAndMintSc {
        vm.startPrank(user);
        sc.approve(address(engine), AMOUNT_TO_MINT);

        (uint256 totalScMinted, uint256 collateralDepositedInUsd) = engine.getAccountInformation(user);

        vm.expectEmit(true, true, false, true, address(engine));
        emit CollateralRedeemed(user, user, weth, AMOUNT_COLLATERAL);

        
        engine.redeemCollateralAndBurn(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);

        (uint256 totalScMintedAfter,uint256 expectedTotalUserCollateralDepositedAmount) = engine.getAccountInformation(user);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);

        uint256 expectedTotal = 2000 * AMOUNT_COLLATERAL;
        assertEq(collateralDepositedInUsd, expectedTotal);
        assertEq(totalScMinted, AMOUNT_TO_MINT);
        assertEq(totalScMintedAfter, 0);
        assertEq(STARTING_ERC20_BALANCE, userBalance);
        assertEq(expectedTotalUserCollateralDepositedAmount, 0);
        vm.stopPrank();
    }

    //////////  Liquidation  //////////////

    function updateUsdPrice(int256 newPrice) internal {
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(newPrice);
    }

    function setEthInSurplusBuffer(uint256 surplusAmount) public {
        ERC20Mock(weth).mint(admin, surplusAmount);

        vm.startPrank(admin);
        ERC20Mock(weth).approve(address(engine), surplusAmount);
        engine.depositSurplus(weth, surplusAmount);
        vm.stopPrank();
    }

    function testGetAndSetSurplusBuffer() public {
        uint256 surplusState = engine.getSurplusBufferState(weth);
        assertEq(surplusState, 0);

        uint256 surplusAmount = 1e18;
        setEthInSurplusBuffer(surplusAmount);

        surplusState = engine.getSurplusBufferState(weth);
        assertEq(surplusState, surplusAmount);
    }

    function testRevertSetSurplusBuffer() public {
        uint256 surplusAmount = 1e18;
        uint256 before = engine.getSurplusBufferState(weth);

        vm.expectRevert();
        engine.depositSurplus(weth, surplusAmount);

        uint256 afterDeposit = engine.getSurplusBufferState(weth);
        assertEq(before, afterDeposit);
    }

    function testSurplusDepositEmit() public {
        uint256 surplusAmount = 1e18;
        vm.startPrank(admin);
        ERC20Mock(weth).approve(address(engine), surplusAmount);

        vm.expectEmit(true, true, true, true, address(engine));
        emit SurplusDeposited(admin, weth, surplusAmount);

        engine.depositSurplus(weth, surplusAmount);
        vm.stopPrank();
    }

    function testLliquidateGoodHealthFactor() public depositedCollateralAndMintSc {
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        sc.approve(address(engine), AMOUNT_TO_MINT);

        uint256 userHealthFactor = engine.getHealthFactor(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                SCEngine.SCEngine__HealthFactorOk.selector,
                userHealthFactor
            )
        );
        
        engine.liquidate(weth, user, AMOUNT_TO_MINT);

        vm.stopPrank();
    }

    function _liquidated(int256 ethUsdUpdatedPrice, uint256 liquidatorAmountToMint) private {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        updateUsdPrice(ethUsdUpdatedPrice);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        engine.depositCollateralAndMintSC(weth, COLLATERAL_TO_COVER, liquidatorAmountToMint);
        sc.approve(address(engine), liquidatorAmountToMint);

        engine.liquidate(weth, user, AMOUNT_TO_MINT);
  
        vm.stopPrank();
    }

    function testRevertInsufficientSurplusBuffer() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 1050 * 1e8; // 105%
        updateUsdPrice(ethUsdUpdatedPrice);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        engine.depositCollateralAndMintSC(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        sc.approve(address(engine), AMOUNT_TO_MINT);

        

        vm.expectRevert(SCEngine.SCEngine__InsufficientSurplusBuffer.selector);

        engine.liquidate(weth, user, AMOUNT_TO_MINT);
  
        vm.stopPrank();
    }
    
    function testLiquidatorStillHasSomeSCAfterLiquidation() public {
        int256 ethUsdUpdatedPrice = 1200 * 1e8;
        uint256 additionalAmountToMint = 400e18;
        _liquidated(ethUsdUpdatedPrice, AMOUNT_TO_MINT + additionalAmountToMint);

        // Calculate expected values
        uint256 price = uint256(ethUsdUpdatedPrice) * ADDITIONAL_FEED_PRECISION; // 18 decimals
        uint256 debtValueInCollateral = (AMOUNT_TO_MINT * 1e18) / price;
        uint256 expectedBonus = debtValueInCollateral / 10; // 10% bonus
        uint256 expectedSurplusCoverage = debtValueInCollateral / 20; // 5% surplus
        uint256 expectedLiquidatorGain = debtValueInCollateral + expectedBonus;

        uint256 liquidatorSCBalance = sc.balanceOf(liquidator);
        assertEq(liquidatorSCBalance, additionalAmountToMint);

        uint256 afterUserDepositAmount = engine.getUserCollateralAmount(user, weth);
        assertEq(
            afterUserDepositAmount,
            AMOUNT_COLLATERAL - expectedLiquidatorGain - expectedSurplusCoverage
        );
    }

    // test colateral below 110%
    function testUserHasBelowCollateralForTheLiquidator() public {
        uint256 surplusAmount = 1e18;
        setEthInSurplusBuffer(surplusAmount);

        uint256 beforeSurplus = engine.getSurplusBufferState(weth);

        int256 ethUsdUpdatedPrice = 1050 * 1e8; // 105%
        _liquidated(ethUsdUpdatedPrice, AMOUNT_TO_MINT);

        // Calculate expected values
        uint256 price = uint256(ethUsdUpdatedPrice) * ADDITIONAL_FEED_PRECISION; // 18 decimals
        uint256 debtValueInCollateral = (AMOUNT_TO_MINT * 1e18) / price;
        uint256 expectedBonus = debtValueInCollateral / 10; // 10% bonus
        uint256 expectedSurplusCoverage = debtValueInCollateral / 20; // 5% surplus

        uint256 afterLiquidated = engine.getSurplusBufferState(weth);
        assertApproxEqAbs(beforeSurplus, afterLiquidated + expectedSurplusCoverage, 2);

        // Verify liquidator balance
        uint256 afterLiquidatorDepositAmount = engine.getUserCollateralAmount(liquidator, weth);
        assertEq(
            afterLiquidatorDepositAmount,
            COLLATERAL_TO_COVER + expectedBonus
        );
        
        uint256 afterUserDepositAmount = engine.getUserCollateralAmount(user, weth);
        assertEq(afterUserDepositAmount, 0);
    }
    // test colateral exact 110%
    function testUserHasExactCollateralForTheLiquidator() public {
        uint256 beforeSurplus = engine.getSurplusBufferState(weth);

        int256 ethUsdUpdatedPrice = 1100 * 1e8; // 110%
        _liquidated(ethUsdUpdatedPrice, AMOUNT_TO_MINT);

        // Calculate expected values
        uint256 price = uint256(ethUsdUpdatedPrice) * ADDITIONAL_FEED_PRECISION; // 18 decimals
        uint256 debtValueInCollateral = (AMOUNT_TO_MINT * 1e18) / price;
        uint256 expectedBonus = debtValueInCollateral / 10; // 10% bonus

        uint256 afterLiquidated = engine.getSurplusBufferState(weth);
        assertApproxEqAbs(afterLiquidated, beforeSurplus, 2);

        // Verify liquidator balance
        uint256 afterLiquidatorDepositAmount = engine.getUserCollateralAmount(liquidator, weth);
        assertEq(
            afterLiquidatorDepositAmount,
            COLLATERAL_TO_COVER + expectedBonus
        );
        
        uint256 afterUserDepositAmount = engine.getUserCollateralAmount(user, weth);
        assertEq(afterUserDepositAmount, 0);
    }
    // test colateral below 100%
    function testUserHasBelowCollateral() public {
        uint256 surplusAmount = 1e18;
        setEthInSurplusBuffer(surplusAmount);

        uint256 beforeSurplus = engine.getSurplusBufferState(weth);

        int256 ethUsdUpdatedPrice = 900 * 1e8; // 90%
        _liquidated(ethUsdUpdatedPrice, AMOUNT_TO_MINT);

        // Calculate expected values
        uint256 price = uint256(ethUsdUpdatedPrice) * ADDITIONAL_FEED_PRECISION; // 18 decimals
        uint256 debtValueInCollateral = (AMOUNT_TO_MINT * 1e18) / price;
        uint256 expectedBonus = debtValueInCollateral / 10; // 10% bonus
        uint256 expectedCoverage = debtValueInCollateral / 10; // 10%

        uint256 afterLiquidated = engine.getSurplusBufferState(weth);
        assertApproxEqAbs(beforeSurplus, afterLiquidated + expectedCoverage + expectedBonus , 2);

        // Verify liquidator balance
        uint256 afterLiquidatorDepositAmount = engine.getUserCollateralAmount(liquidator, weth);
        assertEq(
            afterLiquidatorDepositAmount,
            COLLATERAL_TO_COVER + expectedBonus
        );
        

        // // verify user left 0 AMOUNT_COLLATERAL
        uint256 afterUserDepositAmount = engine.getUserCollateralAmount(user, weth);
        assertEq(afterUserDepositAmount, 0);
    }

    function testHalfUpdateSurplusBuffer() public {
        uint256 beforeSurplus = engine.getSurplusBufferState(weth);

        int256 ethUsdUpdatedPrice = 1125 * 1e8; // 112.5%
        _liquidated(ethUsdUpdatedPrice, AMOUNT_TO_MINT);

        // Calculate expected values
        uint256 price = uint256(ethUsdUpdatedPrice) * ADDITIONAL_FEED_PRECISION; // 18 decimals
        uint256 debtValueInCollateral = (AMOUNT_TO_MINT * 1e18) / price;
        uint256 expectedBonus = debtValueInCollateral / 10; // 10% bonus
        uint256 expectedSurplusIncrease = debtValueInCollateral / 20; // 5% surplus

        uint256 afterLiquidated = engine.getSurplusBufferState(weth);
        assertApproxEqAbs(
            afterLiquidated,
            beforeSurplus + (expectedSurplusIncrease / 2),
            2
        );

        // Verify liquidator balance
        uint256 afterLiquidatorDepositAmount = engine.getUserCollateralAmount(liquidator, weth);
        assertEq(
            afterLiquidatorDepositAmount,
            COLLATERAL_TO_COVER + expectedBonus
        );
        

        // // verify user left 0 AMOUNT_COLLATERAL
        uint256 afterUserDepositAmount = engine.getUserCollateralAmount(user, weth);
        assertEq(afterUserDepositAmount, 0);
    }

    function testLiquidationUpdateSurplusBufferAndUserStillHasSomeEth() public {
        uint256 beforeSurplus = engine.getSurplusBufferState(weth);

        // Set price to $1200 (1200 * 1e8)
        int256 ethUsdUpdatedPrice = 1200 * 1e8; // 120%
        _liquidated(ethUsdUpdatedPrice, AMOUNT_TO_MINT);

        // Calculate expected values
        uint256 price = 1200 * 1e18; // 18 decimals
        uint256 debtValueInCollateral = (AMOUNT_TO_MINT * 1e18) / price;
        uint256 expectedBonus = debtValueInCollateral / 10; // 10% bonus
        uint256 expectedSurplusIncrease = debtValueInCollateral / 20; // 5% surplus
        uint256 expectedLiquidatorGain = debtValueInCollateral + expectedBonus;

        uint256 afterLiquidated = engine.getSurplusBufferState(weth);
        assertEq(afterLiquidated, beforeSurplus + expectedSurplusIncrease);

        // Verify liquidator balance
        uint256 afterLiquidatorDepositAmount = engine.getUserCollateralAmount(liquidator, weth);
        assertEq(
            afterLiquidatorDepositAmount,
            COLLATERAL_TO_COVER + expectedBonus
        );

        // verify user left 5% of AMOUNT_COLLATERAL
        uint256 afterUserDepositAmount = engine.getUserCollateralAmount(user, weth);
        assertEq(
            afterUserDepositAmount,
            AMOUNT_COLLATERAL - expectedLiquidatorGain - expectedSurplusIncrease //5%
        );
    }

}
