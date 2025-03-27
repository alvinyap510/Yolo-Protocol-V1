// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// import "@layerzerolabs/contracts/token/oft/v2/OFTV2.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";

contract OFTV2Token is OFT {
    constructor(string memory _name, string memory _symbol, address _lzEndpoint)
        OFT(_name, _symbol, _lzEndpoint, msg.sender)
    {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }
}
