// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@layerzerolabs/contracts/token/oft/v2/OFTV2.sol";

contract YoloOFTV2 is OFTV2 {
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint
    ) OFTV2(_name, _symbol, 18, _lzEndpoint) {
        // Mint initial supply if needed
        _mint(msg.sender, 1000000 * 10**18); // 1 million tokens with 18 decimals
    }
}