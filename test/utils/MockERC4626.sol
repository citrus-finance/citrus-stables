// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

contract MockERC4626 is ERC4626 {
    uint256 public beforeWithdrawHookCalledCounter = 0;
    uint256 public afterDepositHookCalledCounter = 0;
    uint256 public depositCap = 1e38;

    constructor(address underlying, string memory name, string memory symbol)
        ERC20(name, symbol)
        ERC4626(IERC20(underlying))
    {}

    function setDepositCap(uint256 _depositCap) external {
        depositCap = _depositCap;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return depositCap - totalAssets();
    }
}
