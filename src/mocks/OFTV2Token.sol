// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {
    MessagingReceipt, OFTReceipt, MessagingFee, SendParam
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

contract OFTV2Token is OFT {
    constructor(string memory _name, string memory _symbol, address _lzEndpoint)
        OFT(_name, _symbol, _lzEndpoint, msg.sender)
    {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    function simpleQuoteSend(
        uint32 _dstEid,
        bytes32 _to,
        uint256 _amountLD,
        uint256 _minAmountLD,
        bytes calldata _extraOptions
    ) external view returns (MessagingFee memory msgFee) {
        // Build the SendParam struct
        SendParam memory sendParam = SendParam({
            dstEid: _dstEid,
            to: _to,
            amountLD: _amountLD,
            minAmountLD: _minAmountLD,
            extraOptions: _extraOptions,
            composeMsg: "", // No composed message for a simple transfer
            oftCmd: "" // No custom OFT command
        });
        return this.quoteSend(sendParam, false);
    }
}
