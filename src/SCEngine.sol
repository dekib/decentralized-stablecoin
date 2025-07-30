// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableCoin} from "./StableCoin.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// todo Or better yet, use OpenZeppelin's SafeERC20 library

/*
 * @title SCEngine
 * @author Dejan Jovanovic
 * @notice Thanks Patrick Colins from Chainlink
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * This contract is based on the MakerDAO DSS system.
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our SC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the SC.
 *
 */
contract SCEngine is ReentrancyGuard {
    error SCEngine__NeedsMoreThanZero();
    error SCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error SCEngine__TokenNotAllowed();
    error SCEngine__TransferFailed();
    error SCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error SCEngine__MintFailed();
    error SCEngine__HealthFactorOk(uint256 userHealthFactor);
    error SCEngine__HealthFactorNotImproved();
    error SCEngine__PriceIsZero();
    error SCEngine__GreaterAmountThanTheDebt(uint256 debtToCover);
    error SCEngine__InsufficientUserCollateral();
    error SCEngine__StalePrice();
    error SCEngine__PriceFeedTimeout();
    error SCEngine__InsufficientContractBalance();
    error SCEngine__InsufficientSurplusBuffer();
    error SCEngine__OverflowInUsdValueCalculation();

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e8; // 1e10/1e18
    uint256 private constant PRECISION = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 75; // 75%
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_BONUS = 10;
    uint256 private constant SURPLUS_BONUS = 2;
    uint256 private constant HOUR_IN_SEC = 3600;

    mapping(address token => address priceFeed) private s_priceFeeds; // price data on-chain
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountSCMinted) private s_SCMinted; // debit
    mapping(address token => uint256 amount) private s_surplusBuffer;
    address[] private s_collateralTokens;

    StableCoin private immutable i_sc;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    event LiquidationExecuted(address indexed user, address insolventCollateral, uint256 debtToCover, uint256 totalCollateralToRedeem, address indexed liquidator);
    event SurplusDeposited(address indexed user, address indexed token, uint256 amount);

    modifier isMoreThanZero(uint256 amount) {
        if (amount == 0) {
            revert SCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert SCEngine__TokenNotAllowed();
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address scAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert SCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_sc = StableCoin(scAddress);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        isMoreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _depositCollateral(tokenCollateralAddress, amountCollateral); // why implementation is not here and we need to call _depositCollateral
    }

    /*
     * @param amountSCToMint: The amount of SC you want to mint or borrow
     * You can only mint SC if you have enough collateral
     */
    function mintSC(uint256 amountSCToMint) public isMoreThanZero(amountSCToMint) nonReentrant {
        _mintSC(amountSCToMint);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountSCToMint: The amount of SC you want to mint
     * @notice deposit your collateral and mint SC in one transaction
     */
    function depositCollateralAndMintSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountSCToMint
    )
        external
        isMoreThanZero(amountCollateral)
        isMoreThanZero(amountSCToMint)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _depositCollateral(tokenCollateralAddress, amountCollateral);
        _mintSC(amountSCToMint);
    }

    /*
     * @param tokenAddress: The ERC20 token address of the token you're depositing
     * @param amount: The amount of token you're depositingin surplus buffer
     */
    function depositSurplus(address tokenAddress, uint256 amount)
        public
        isMoreThanZero(amount)
        isAllowedToken(tokenAddress)
        nonReentrant
    {
        _depositSurplus(tokenAddress, amount);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @notice This function will redeem your collateral.
     * @notice If you have SC minted, you will not be able to redeem until you burn your SC ~~~
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
        isMoreThanZero(amountCollateral)
    {
        _setCollateralDeposited(tokenCollateralAddress, amountCollateral, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnSc(uint256 amount) external isMoreThanZero(amount) {
        _burnSc(amount, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountScToBurn: The amount of SC you want to burn
     * @notice redeems your collateral and burn SC in one transaction
     */
    function redeemCollateralAndBurn(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountScToBurn)
        external
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
        isMoreThanZero(amountCollateral)
    {
        _setCollateralDeposited(tokenCollateralAddress, amountCollateral, msg.sender);
        _burnSc(amountScToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // // todo
    // function emergencyWithdrawToken(address token) external onlyOwner {
    //      uint256 balance = IERC20(token).balanceOf(address(this));
    //      IERC20(token).transfer(owner(), balance);
    //  }

    /*
     * @param insolventCollateral: The ERC20 token address of the collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your SC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of SC you want to burn to cover the user's debt.
     *
     * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% liquidation bonus in your deposit for taking the user's funds.
     */
    function liquidate(address insolventCollateral, address user, uint256 debtToCover)
        external
        isAllowedToken(insolventCollateral)
        isMoreThanZero(debtToCover)
        nonReentrant
    {
        /* liquidator burn badUser SC debt and take their collateral
        for example badUser has collateral ETH in value of $140 , and $100 SC
        liquidator need to cover (debtToCover) $100 SC
        */
        uint256 initialUserHealthFactor = _healthFactor(user);
        if (initialUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert SCEngine__HealthFactorOk(initialUserHealthFactor);
        }

        if (debtToCover > s_SCMinted[user]) {
            revert SCEngine__GreaterAmountThanTheDebt(debtToCover);
        }

        uint256 totalCollateralToRedeem =_handleSurplusBuffer(insolventCollateral,debtToCover, user);

        _burnSc(debtToCover, user, msg.sender);

        // check verifies that the health factor improves after liquidation 
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= initialUserHealthFactor) {
            revert SCEngine__HealthFactorNotImproved();
        }

        /* The first check ensures that the liquidation process improves the user's situation 
        (i.e., their health factor increases or at least does not decrease).
The second check ensures that the user's health factor remains above the minimum after the liquidation.
It serves as an additional safeguard to prevent the health factor from becoming dangerous post-liquidation.*/

        _revertIfHealthFactorIsBroken(msg.sender);

        emit LiquidationExecuted(user, insolventCollateral, debtToCover, totalCollateralToRedeem, msg.sender);
    }

    // External & Public View & Pure Functions //
 
    function getUserCollateralDepositedInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];

            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmount) public view isMoreThanZero(usdAmount) returns (uint256) {
        uint256 price = _getUsdPrice(token);
        // price: The returned value from Chainlink will be 2000 * 1e8 / 1 ETH = 2000 USD
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmount * ADDITIONAL_FEED_PRECISION) / price);
    }

    // Helper functions for test //

    function getUsdValue(address token, uint256 amount) 
        external
        view
        returns (uint256)
    {
        return _getUsdValue(token, amount);
    }

    function getSurplusBufferState(address token)
        external
        view
        returns (uint256)
    {
        return s_surplusBuffer[token];
    }

    function getHealthFactor(address user)
        external
        view
        returns (uint256)
    {
        return _healthFactor(user);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalScMinted, uint256 collateralValueInUsd)
    {
        (totalScMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getUserCollateralAmount(address user, address tokenCollateralAddress)
        external
        view
        returns (uint256 collateralAmount)
    {
        collateralAmount = s_collateralDeposited[user][tokenCollateralAddress];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    // private & internal functions

    function _handleSurplusBuffer(
        address insolventCollateral,
        uint256 debtToCover,       
        address user
        ) private returns(uint256) {
        uint256 tokenAmountFromScDebt = getTokenAmountFromUsd(insolventCollateral, debtToCover);

        uint256 liquidatorBonus = (tokenAmountFromScDebt / LIQUIDATION_BONUS); // 10%
        uint256 liquidatorCollateralToRedeem = liquidatorBonus + tokenAmountFromScDebt; // 110% of debt in ETH
        uint256 surplusCollateralToRedeem = (liquidatorBonus / SURPLUS_BONUS); // 5%
        uint256 totalCollateralToRedeem = surplusCollateralToRedeem + liquidatorCollateralToRedeem;
        uint256 userCollateral = s_collateralDeposited[user][insolventCollateral];

        if (liquidatorCollateralToRedeem > userCollateral) {
            uint256 missingCollateral = liquidatorCollateralToRedeem - userCollateral;
            s_collateralDeposited[user][insolventCollateral] = 0;
 
            /* For your off-chain app you can choose the polling approach periodically calls
            the `getSurplusBufferState` function to check the value of surplusBuffer.*/
            if (s_surplusBuffer[insolventCollateral] < missingCollateral) {
                revert SCEngine__InsufficientSurplusBuffer();
            }
            s_surplusBuffer[insolventCollateral] -= missingCollateral;
        } else {
            if (totalCollateralToRedeem > userCollateral) {
                uint256 surplusPart = userCollateral - liquidatorCollateralToRedeem;
                s_surplusBuffer[insolventCollateral] += surplusPart;

                s_collateralDeposited[user][insolventCollateral] = 0; 
            } else {
                s_collateralDeposited[user][insolventCollateral] -= totalCollateralToRedeem;
                s_surplusBuffer[insolventCollateral] += surplusCollateralToRedeem;

            }
        }
        // // Transfer incentive to liquidator
        s_collateralDeposited[msg.sender][insolventCollateral] += liquidatorBonus;

        return liquidatorCollateralToRedeem;
    }

    function _getUsdPrice(address token) internal view isAllowedToken(token) returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,uint256 updatedAt,) = priceFeed.latestRoundData();
 
        if (price <= 0) {
            revert SCEngine__PriceIsZero();
        }

        if (updatedAt == 0) {
            revert SCEngine__StalePrice();
        }

        if(block.timestamp > updatedAt + HOUR_IN_SEC) {
            revert SCEngine__StalePrice();
        } 

        return uint256(price);
    }

    function _getUsdValue(address token, uint256 amount) 
        internal
        view
        returns (uint256)
    {
        if (amount == 0) {
            return 0;
        }
        uint256 price = _getUsdPrice(token);

        uint256 value = price * amount;
        if (value / price != amount) {
            revert SCEngine__OverflowInUsdValueCalculation();
        }

        return value / ADDITIONAL_FEED_PRECISION;
    }

    /*
     * @dev internal function, the parent needs to check the nonReentrant, isAllowedToken and isMoreThanZero
     */
    function _depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) private {
        bool ok = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!ok) {
            revert SCEngine__TransferFailed();
        }

        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
    }

    /*
     * @dev internal function, the parent needs to check the nonReentrant, isAllowedToken and isMoreThanZero
     */
    function _depositSurplus(address tokenAddress, uint256 amount) private {
        s_surplusBuffer[tokenAddress] += amount;
        emit SurplusDeposited(msg.sender, tokenAddress, amount);

        bool ok = IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
        if (!ok) {
            revert SCEngine__TransferFailed();
        }
    }

    /*
     * @dev internal function, the parent needs to check the nonReentrant and isMoreThanZero
     */
    function _mintSC(uint256 amountSCToMint) private {
        s_SCMinted[msg.sender] += amountSCToMint;

        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_sc.mint(msg.sender, amountSCToMint);
        if (!minted) {
            revert SCEngine__MintFailed();
        }
    }

    /*
     * @dev internal function, the parent needs to check a health factor and amount Sc To Burn
     */
    function _burnSc(uint256 amountScToBurn, address onBehalfOf, address scPayer) private {
        s_SCMinted[onBehalfOf] -= amountScToBurn;

        bool ok = i_sc.transferFrom(scPayer, address(this), amountScToBurn);

        if (!ok) {
            revert SCEngine__TransferFailed();
        }

        i_sc.burn(amountScToBurn);
    }

    function _setCollateralDeposited(address tokenCollateralAddress, uint256 amountCollateral, address from)
        private
    {
        if (amountCollateral > s_collateralDeposited[from][tokenCollateralAddress]) {
            revert SCEngine__InsufficientUserCollateral();
        }

        // Ensures SCEngine has sufficient balance
        if (amountCollateral > IERC20(tokenCollateralAddress).balanceOf(address(this))) {
            revert SCEngine__InsufficientContractBalance();
        }

        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
    }

    /*
     * @dev internal function, the parent needs to check an Insufficient User Collateral and set CollateralDeposited
     */
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        bool ok = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!ok) {
            revert SCEngine__TransferFailed();
        }
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalSCMinted, uint256 collateralInUsd)
    {
        totalSCMinted = s_SCMinted[user];
        collateralInUsd = getUserCollateralDepositedInUsd(user);
    }

    /*
    * Returns how close to liquidation a user is
    */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalSCMinted, uint256 collateralInUsd) = _getAccountInformation(user);
        if (totalSCMinted == 0) return type(uint256).max;

        uint256 collateralAdjustedForTreshold = collateralInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;

        return (collateralAdjustedForTreshold * PRECISION) / totalSCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        
        if (userHealthFactor < MIN_HEALTH_FACTOR) { // 1e18
            revert SCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
}
