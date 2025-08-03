// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {Share} from "../src/Share.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockERC4626} from "./utils/MockERC4626.sol";

contract ShareTest is Test {
    address owner = makeAddr("owner");

    MockERC20 asset = new MockERC20("USD", "USD", 18);
    IERC4626 vault = IERC4626(address(new MockERC4626(address(asset), "Mock Token Vault", "vwTKN")));
    Share share = new Share("Citrus USD", "cUSD", 18);
    SyntheticVault syntheticVault =
        new SyntheticVault(address(asset), address(share), address(vault), owner, address(this));

    function setUp() public {
        vm.warp(7 days);

        share.addMinter(address(syntheticVault));
        share.setYieldSetter(address(this));
        share.transferOwnership(owner);

        vm.prank(owner);
        syntheticVault.setDepositCapLimit(type(uint256).max);

        syntheticVault.setDepositCap(type(uint256).max);

        // ~1% yield per week
        share.setYield(16452266757640263534, 1);
        share.setYield(16452266757640263534, 2);
    }

    function test_NonRebasingByDefault() public {
        _mint(1e18);

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 1e18);
    }

    function test_RebasingOptIn() public {
        _mint(1e18);

        share.rebaseOptIn();

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 1.01e18);
    }

    function test_RebasingOptOut() public {
        _mint(1e18);

        share.rebaseOptIn();

        skip(7 days);

        uint256 balance = share.balanceOf(address(this));

        assertEq(balance, 1.01e18);

        share.rebaseOptOut();

        skip(7 days);

        assertEq(share.balanceOf(address(this)), balance);
    }

    function test_TransferNonRebasingToNonRebasing() public {
        _mint(1e18);

        address recipient = makeAddr("recipient");

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 1e18);
        assertEq(share.balanceOf(recipient), 0);

        share.transfer(recipient, 1e18);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), 1e18);

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), 1e18);
    }

    /// forge-config: default.fuzz.runs = 10000
    function test_FuzzTransferNonRebasingToNonRebasing(uint136 amount, uint32 yield) public {
        vm.assume(amount > 0 && amount <= 1e38);

        share.setYield(yield, 1);
        _mint(amount);

        address recipient = makeAddr("recipient");

        skip(7 days);

        assertEq(share.balanceOf(address(this)), amount);
        assertEq(share.balanceOf(recipient), 0);

        share.transfer(recipient, amount);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), amount);

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), amount);
    }

    function test_TransferRebasingToNonRebasing() public {
        _mint(1e18);

        share.rebaseOptIn();

        skip(7 days);

        address recipient = makeAddr("recipient");

        assertEq(share.balanceOf(address(this)), 1.01e18);
        assertEq(share.balanceOf(recipient), 0);

        share.transfer(recipient, share.balanceOf(address(this)));

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), 1.01e18);

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), 1.01e18);
    }

    /// forge-config: default.fuzz.runs = 10000
    function test_FuzzTransferRebasingToNonRebasing(uint136 amount, uint32 yield) public {
        vm.assume(amount > 0 && amount <= 1e38);

        share.setYield(yield, 1);
        _mint(amount);

        share.rebaseOptIn();

        skip(7 days);

        address recipient = makeAddr("recipient");

        uint256 toTransfer = share.balanceOf(address(this));

        share.transfer(recipient, toTransfer);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), toTransfer);
    }

    function test_TransferNonRebasingToRebasing() public {
        _mint(1e18);

        address recipient = makeAddr("recipient");

        vm.prank(recipient);
        share.rebaseOptIn();

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 1e18);
        assertEq(share.balanceOf(recipient), 0);

        share.transfer(recipient, 1e18);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), 1e18);

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), 1.01e18);
    }

    /// forge-config: default.fuzz.runs = 10000
    function test_FuzzTransferNonRebasingToRebasing(uint136 amount, uint32 yield) public {
        vm.assume(amount > 0 && amount <= 1e38);

        share.setYield(yield, 1);
        _mint(amount);

        asset.mint(address(this), amount);
        asset.approve(address(syntheticVault), amount);

        syntheticVault.deposit(amount, address(this));

        address recipient = makeAddr("recipient");

        vm.prank(recipient);
        share.rebaseOptIn();

        skip(7 days);

        uint256 amountToTransfer = share.balanceOf(address(this));

        share.transfer(recipient, amountToTransfer);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), amountToTransfer);
    }

    function test_TransferRebasingToRebasing() public {
        _mint(1e18);

        share.rebaseOptIn();

        address recipient = makeAddr("recipient");

        vm.prank(recipient);
        share.rebaseOptIn();

        skip(7 days);

        uint256 transferAmount = share.balanceOf(address(this));

        assertEq(transferAmount, 1.01e18);
        assertEq(share.balanceOf(address(this)), transferAmount);

        share.transfer(recipient, transferAmount);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(transferAmount, 1.01e18);

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), 1.0201e18);
    }

    /// forge-config: default.fuzz.runs = 10000
    function test_FuzzTransferRebasingToRebasing(uint136 amount, uint32 yield) public {
        vm.assume(amount > 0 && amount <= 1e38);

        share.setYield(yield, 1);
        _mint(amount);

        share.rebaseOptIn();

        address recipient = makeAddr("recipient");

        vm.prank(recipient);
        share.rebaseOptIn();

        skip(7 days);

        uint256 amountToTransfer = share.balanceOf(address(this));

        share.transfer(recipient, amountToTransfer);

        assertEq(share.balanceOf(address(this)), 0);
        assertEq(share.balanceOf(recipient), amountToTransfer);
    }

    function test_CurrentWeekYield() public {
        share.rebaseOptIn();

        _mint(1e18);

        // ~1% yield per week
        share.setYield(16452266757640263534, 1);

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 1.01e18);
    }

    function test_SkipWeekWhenNoYieldSet() public {
        share.rebaseOptIn();

        // ~1% yield per week
        share.setYield(16452266757640263534, 1);
        share.setYield(0, 2);
        share.setYield(16452266757640263534, 3);

        _mint(1e18);

        // assertEq(share.balanceOf(address(this)), 1e18);

        skip(7 days);

        uint256 balanceAfterFirstWeek = share.balanceOf(address(this));

        assertEq(balanceAfterFirstWeek, 1.01e18);

        skip(7 days);

        // Balance should not change since no yield was set for the second week
        assertEq(share.balanceOf(address(this)), balanceAfterFirstWeek);

        skip(7 days);

        assertEq(share.balanceOf(address(this)), 1.0201e18);
    }

    function test_DailyYield() public {
        share.rebaseOptIn();

        _mint(1e18);

        // ~1% yield per week
        share.setYield(16452266757640263534, 1);

        skip(1 days);
        uint256 dayOneBalance = share.balanceOf(address(this));

        skip(1 days);
        uint256 dayTwoBalance = share.balanceOf(address(this));

        skip(1 days);
        uint256 dayThreeBalance = share.balanceOf(address(this));

        skip(1 days);
        uint256 dayFourBalance = share.balanceOf(address(this));

        skip(1 days);
        uint256 dayFiveBalance = share.balanceOf(address(this));

        skip(1 days);
        uint256 daySixBalance = share.balanceOf(address(this));

        skip(1 days);
        uint256 daySevenBalance = share.balanceOf(address(this));

        assertGt(dayOneBalance, 1e18);
        assertGt(dayTwoBalance, dayOneBalance);
        assertGt(dayThreeBalance, dayTwoBalance);
        assertGt(dayFourBalance, dayThreeBalance);
        assertGt(dayFiveBalance, dayFourBalance);
        assertGt(daySixBalance, dayFiveBalance);
        assertGt(daySevenBalance, daySixBalance);
        assertEq(daySevenBalance, 1.01e18);
    }

    function _mint(uint256 amount) internal {
        asset.mint(address(this), amount);
        asset.approve(address(syntheticVault), amount);

        syntheticVault.deposit(amount, address(this));
    }
}
