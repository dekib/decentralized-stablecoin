// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockV3Aggregator } from "./MockV3Aggregator.sol";

/*
 * @title StableCoin
 * @author Dejan Jovanovic
 * Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 *
 * This is the contract meant to be owned by SCEngine.
 * It is a ERC20 token that can be minted and burned by the SCEngine smart contract.
 */
contract MockMoreDebtSC is ERC20Burnable, Ownable {
    error StableCoin__AmountMustBeMoreThanZero();
    error StableCoin__BurnAmountExceedsBalance();
    error StableCoin__ZeroAddress();

    address mockAggregator;

    constructor(address _mockAggregator) ERC20("StableCoin", "SC") Ownable(msg.sender) {
        mockAggregator = _mockAggregator;
    }

    function burn(uint256 _amount) public override onlyOwner {
        MockV3Aggregator(mockAggregator).updateAnswer(0);
        uint256 balance = balanceOf(msg.sender);

        if (_amount <= 0) {
            revert StableCoin__AmountMustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert StableCoin__BurnAmountExceedsBalance();
        }

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert StableCoin__ZeroAddress();
        }
        if (_amount <= 0) {
            revert StableCoin__AmountMustBeMoreThanZero();
        }

        _mint(_to, _amount);
        return true;
    }
}
