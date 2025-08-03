// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library ArrayLib {
    function toArray(address value1) public pure returns (address[] memory) {
        address[] memory result = new address[](1);
        result[0] = value1;
        return result;
    }

    function toArray(address value1, address value2) public pure returns (address[] memory) {
        address[] memory result = new address[](2);
        result[0] = value1;
        result[1] = value2;
        return result;
    }
}
