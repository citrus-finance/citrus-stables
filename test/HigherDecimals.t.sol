// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {ERC7575Test} from "erc7575-tests/ERC7575.test.sol";
import {Test} from "forge-std/Test.sol";

import {MockERC20} from "./utils/MockERC20.sol";
import {MockERC4626} from "./utils/MockERC4626.sol";

import {Share} from "../src/Share.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";

contract HigherDecimalsTest is ERC7575Test {
    function setUp() public override {
        _underlying_ = address(new MockERC20("USD Coin", "USDC", 6));
        _share_ = address(new Share(address(this), "Citrus USD", "cUSD", 18));
        _vault_ = address(
            new SyntheticVault(
                _underlying_,
                _share_,
                address(new MockERC4626(_underlying_, "Mock Token Vault", "vwTKN")),
                address(this),
                address(this)
            )
        );
        Share(_share_).addMinter(_vault_);
        SyntheticVault(_vault_).setDepositCapLimit(type(uint256).max);
        // NOTE: we have a reduce the deposit cap due to the lower decimals of the underlying token
        SyntheticVault(_vault_).setDepositCap(type(uint256).max);
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = false;
    }

    function setUpYield(Init memory init) public override {}

    function test_maxDeposit(Init memory init) public override {
        SyntheticVault(_vault_).setDepositCap(1e38);
        super.test_maxDeposit(init);
    }

    function test_maxMint(Init memory init) public override {
        SyntheticVault(_vault_).setDepositCap(1e38);
        super.test_maxMint(init);
    }

    function test_totalAssets(Init memory init) public override {
        SyntheticVault(_vault_).setDepositCap(1e38);
        super.test_totalAssets(init);
    }

    function test_ShareDecimal() public {
        MockERC20(_underlying_).mint(address(this), 1e6);
        MockERC20(_underlying_).approve(_vault_, 1e6);

        SyntheticVault(_vault_).deposit(1e6, address(this));

        uint256 shares = Share(_share_).balanceOf(address(this));
        assertEq(shares, 1e18);
    }
}
