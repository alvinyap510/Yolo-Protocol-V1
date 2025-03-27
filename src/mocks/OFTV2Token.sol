// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@layerzerolabs/contracts/token/oft/v2/OFTV2.sol";

contract OFTV2Token is OFTV2 {
    constructor(string memory _name, string memory _symbol, address _lzEndpoint)
        OFTV2(_name, _symbol, 18, _lzEndpoint)
    {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }
}
