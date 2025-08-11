// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Share} from "../src/Share.sol";
import {YieldSetter} from "../src/YieldSetter.sol";

contract YieldSetterTest is Test {
    address signer;
    uint256 signerPK;

    YieldSetter yieldSetter;
    Share share;

    function setUp() public {
        (signer, signerPK) = makeAddrAndKey("signer");

        share = new Share(address(this), "Citrus USD", "cUSD", 18);
        yieldSetter = new YieldSetter(address(this), signer, address(share), type(uint256).max);
        share.setYieldSetter(address(yieldSetter));
    }

    function test_SetYield() public {
        uint256 week = 0;
        uint256 nonce = 0;
        uint256 yield = 1000;
        bytes32 r;
        bytes32 s;
        uint8 v;

        (v, r, s) = vm.sign(signerPK, yieldSetter.getSetYieldMessageHash(yield, week, nonce));

        yieldSetter.setYield(yield, week, nonce, v, r, s);

        assertEq(share.yieldByWeek(week), yield);
    }

    function test_OverrideYield() public {
        uint256 week = 0;
        uint256 nonce = 0;
        uint256 yield = 1000;
        bytes32 r;
        bytes32 s;
        uint8 v;

        (v, r, s) = vm.sign(signerPK, yieldSetter.getSetYieldMessageHash(yield, week, nonce));

        yieldSetter.setYield(yield, week, nonce, v, r, s);

        assertEq(share.yieldByWeek(week), 1000);

        yield = 2000;
        nonce = 1;

        (v, r, s) = vm.sign(signerPK, yieldSetter.getSetYieldMessageHash(yield, week, nonce));

        yieldSetter.setYield(yield, week, nonce, v, r, s);

        assertEq(share.yieldByWeek(week), 2000);
    }

    function test_TryToSetAboveMaxYield() public {
        yieldSetter.setMaxYield(100);

        uint256 week = 0;
        uint256 nonce = 0;
        uint256 yield = 1000;
        bytes32 r;
        bytes32 s;
        uint8 v;

        (v, r, s) = vm.sign(signerPK, yieldSetter.getSetYieldMessageHash(yield, week, nonce));

        vm.expectRevert();
        yieldSetter.setYield(yield, week, nonce, v, r, s);
    }

    function test_TryToUseLowerYieldNonce() public {
        uint256 week = 0;
        uint256 nonce = 0;
        uint256 yield = 1000;
        bytes32 r;
        bytes32 s;
        uint8 v;

        (v, r, s) = vm.sign(signerPK, yieldSetter.getSetYieldMessageHash(yield, week, nonce));

        yieldSetter.setYield(yield, week, nonce, v, r, s);

        assertEq(share.yieldByWeek(week), yield);

        nonce = 0;
        yield = 2000;

        (v, r, s) = vm.sign(signerPK, yieldSetter.getSetYieldMessageHash(yield, week, nonce));

        vm.expectRevert();
        yieldSetter.setYield(yield, week, nonce, v, r, s);
    }

    function test_TryToSetYieldWithInvalidSignature() public {
        uint256 week = 0;
        uint256 nonce = 0;
        uint256 yield = 1000;
        bytes32 r;
        bytes32 s;
        uint8 v;

        (, uint256 invalidSignerPK) = makeAddrAndKey("invalidSigner");

        (v, r, s) = vm.sign(invalidSignerPK, yieldSetter.getSetYieldMessageHash(yield, week, nonce));

        vm.expectRevert();
        yieldSetter.setYield(yield, week, nonce, v, r, s);
    }
}
