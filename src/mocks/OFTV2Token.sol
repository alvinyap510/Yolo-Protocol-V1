// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";

contract OFTV2Token is OFT {
    constructor(string memory _name, string memory _symbol, address _lzEndpoint)
        OFT(_name, _symbol, _lzEndpoint, msg.sender)
    {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    /**
     * @dev Simplified function of send() to transfer tokens across chains.
     * @param _dstEid Destination chain endpoint ID.
     * @param _to Recipient address on the destination chain (bytes32 format).
     * @param _amountLD Amount to transfer in local decimals.
     * @param _minAmountLD Minimum amount to receive on the destination chain in local decimals.
     * @param _extraOptions Additional options for the LayerZero message (e.g., executor gas settings).
     * @return msgReceipt The LayerZero messaging receipt.
     * @return oftReceipt The OFT transfer receipt.
     */
    function transferCrossChain(
        uint32 _dstEid,
        bytes32 _to,
        uint256 _amountLD,
        uint256 _minAmountLD,
        bytes calldata _extraOptions
    ) external payable returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
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

        // Estimate the messaging fee
        MessagingFee memory fee = quoteSend(sendParam, false); // Pay in native token, not ZRO

        // Ensure enough native token is provided to cover the fee
        require(msg.value >= fee.nativeFee, "Insufficient native fee provided");

        // Execute the send operation
        (msgReceipt, oftReceipt) = send(sendParam, fee, msg.sender);

        // Refund excess native token if any
        if (msg.value > fee.nativeFee) {
            (bool success,) = msg.sender.call{value: msg.value - fee.nativeFee}("");
            require(success, "Refund failed");
        }
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
        return quoteSend(sendParam, false);
    }
}
