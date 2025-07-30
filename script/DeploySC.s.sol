// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {StableCoin} from "../src/StableCoin.sol";
import {SCEngine} from "../src/SCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeploySC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (StableCoin, SCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            config.activeNetworkConfig();

        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        StableCoin sc = new StableCoin();
        SCEngine engine = new SCEngine(tokenAddresses, priceFeedAddresses, address(sc));

        sc.transferOwnership(address(engine));
        vm.stopBroadcast();

        return (sc, engine, config);
    }
}
