// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {MockERC20} from "solady/../test/utils/mocks/MockERC20.sol";
import {MockERC4626} from "solady/../test/utils/mocks/MockERC4626.sol";

import {ArrayLib} from "./utils/ArrayLib.sol";

import {Share} from "../src/Share.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";

contract SyntheticVaultTest is Test {
    MockERC20 asset = new MockERC20("USD", "USD", 18);
    IERC4626 vault = IERC4626(address(new MockERC4626(address(asset), "Mock Vault", "MVLT", false, 0)));
    Share share = new Share("Citrus USD", "cUSD", 18);
    SyntheticVault syntheticVault =
        new SyntheticVault(address(asset), address(share), address(vault), address(this), address(this));

    function setUp() public {
        share.addMinter(address(syntheticVault));
        syntheticVault.setDepositCapLimit(type(uint256).max);
        syntheticVault.setDepositCap(type(uint256).max);
    }

    function test_NotEnoughAssetForInnerVaultShare() public {
        // Attack the inner vault
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);

        asset.mint(attacker, 1e18);
        asset.approve(address(vault), 1e18);

        vault.deposit(1, attacker);

        // Attack: modify the share / asset ratio in the inner vault
        asset.mint(address(vault), 99);

        vm.stopPrank();

        asset.mint(address(this), 199);
        asset.approve(address(syntheticVault), 199);

        syntheticVault.deposit(199, address(this));
        syntheticVault.withdraw(199, address(this), address(this));

        assertEq(asset.balanceOf(address(this)), 199, "Balance should be 199 after deposit and withdraw");
    }
}
