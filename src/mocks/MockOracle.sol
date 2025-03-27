// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

contract MockOracle {
    uint256 public underlyingPrice;

    constructor(uint256 _initialUnderlyingPrice) {
        underlyingPrice = _initialUnderlyingPrice;
    }

    function get(bytes calldata /* data */ ) external returns (bool success, uint256 rate) {
        return (true, _get());
    }

    function _get() internal view returns (uint256) {
        return 1e26 / underlyingPrice;
    }

    // In 8 decimals
    // e.g. 1 ETH = 2000 USD => 2000 * 10^8
    function setPrice(uint256 _underlyingPrice) external {
        underlyingPrice = _underlyingPrice;
    }
}
