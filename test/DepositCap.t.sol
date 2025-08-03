// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {ArrayLib} from "./utils/ArrayLib.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockERC4626} from "./utils/MockERC4626.sol";

import {Share} from "../src/Share.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";

contract DepositCapTest is Test {
    address owner = makeAddr("owner");

    MockERC20 asset = new MockERC20("USD", "USD", 18);
    address vault = address(new MockERC4626(address(asset), "Mock Token Vault", "vwTKN"));
    Share share = new Share("Citrus USD", "cUSD", 18);

    SyntheticVault syntheticVault = new SyntheticVault(address(asset), address(share), vault, owner, address(this));

    function setUp() public {
        share.addMinter(address(syntheticVault));

        vm.prank(owner);
        syntheticVault.setDepositCapLimit(type(uint256).max);

        syntheticVault.setDepositCap(type(uint256).max);
    }

    function test_DepositDisabled() public {
        syntheticVault.setDepositCap(0);

        asset.mint(address(this), 1e18);
        asset.approve(address(syntheticVault), 1e18);

        vm.expectRevert();
        syntheticVault.deposit(1e18, address(this));
    }

    function test_WithdrawWithDepositDisabled() public {
        asset.mint(address(this), 1e18);
        asset.approve(address(syntheticVault), 1e18);
        syntheticVault.deposit(1e18, address(this));

        syntheticVault.setDepositCap(0);

        syntheticVault.withdraw(1e18, address(this), address(this));
    }

    function test_DepositCap() public {
        syntheticVault.setDepositCap(100e18);

        asset.mint(address(this), 200e18);
        asset.approve(address(syntheticVault), 200e18);

        syntheticVault.deposit(100e18, address(this));

        vm.expectRevert();
        syntheticVault.deposit(1e18, address(this));
    }

    function test_SetDepositCapLimit() public {
        vm.prank(owner);
        syntheticVault.setDepositCapLimit(100e18);

        asset.mint(address(this), 200e18);
        asset.approve(address(syntheticVault), 200e18);

        syntheticVault.deposit(100e18, address(this));

        vm.expectRevert();
        syntheticVault.deposit(1e18, address(this));
    }

    function test_InnerVaultDepositCap() public {}
}
