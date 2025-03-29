// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "@yolo/contracts/mocks/OFTV2Token.sol";
import {
    MessagingReceipt, OFTReceipt, MessagingFee, SendParam
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

contract Script_Misc_OFT_03_CrossChainTransfer is Script {
    // LayerZero endpoint and chain IDs
    address constant lzEndpoint = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    uint16 constant SEPOLIA_LZ_CHAIN_ID = 40161;
    uint16 constant ARB_SEPOLIA_LZ_CHAIN_ID = 40231;

    // Hardcode the deployed contract addresses (replace with actual addresses from deployment)
    address constant SEPOLIA_OFT_ADDRESS = 0x48AAd4E5E88C0fc956C7FF9f6a4E747f759F8815;
    address constant ARB_SEPOLIA_OFT_ADDRESS = 0x4F412844eA94Be760B72e02973Aa1d0a74a5D6F1;

    function run() external {
        string memory RPC_SEPOLIA = vm.envString("RPC_SEPOLIA");
        string memory RPC_ARBITRUM_SEPOLIA = vm.envString("RPC_ARBITRUM_SEPOLIA");

        // Load deployer
        uint256 deployerPrivateKey = vm.envUint("TEST_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployer);

        // Instantiate the token contracts
        OFTV2Token sepoliaOFTV2Token = OFTV2Token(SEPOLIA_OFT_ADDRESS);
        OFTV2Token arbSepoliaOFTV2Token = OFTV2Token(ARB_SEPOLIA_OFT_ADDRESS);

        // Step 1: Fetch initial balances
        vm.createSelectFork(RPC_SEPOLIA);
        uint256 sepoliaInitialBalance = sepoliaOFTV2Token.balanceOf(deployer);
        console.log("Initial Sepolia balance of deployer:", sepoliaInitialBalance / 10 ** 18, "MOT");
        console.log("Initial Total Supply:", sepoliaOFTV2Token.totalSupply() / 10 ** 18, "MOT");

        vm.createSelectFork(RPC_ARBITRUM_SEPOLIA);
        uint256 arbSepoliaInitialBalance = arbSepoliaOFTV2Token.balanceOf(deployer);
        console.log("Initial Arbitrum Sepolia balance of deployer:", arbSepoliaInitialBalance / 10 ** 18, "MOT");
        console.log("Initial Total Supply:", arbSepoliaOFTV2Token.totalSupply() / 10 ** 18, "MOT");

        uint256 TRANSFER_AMOUNT = sepoliaInitialBalance / 5;

        console.log("Transfer Amount: ", TRANSFER_AMOUNT);

        uint256 TRANSFER_AMOUNT_SHARED_DECIMALS_CONVERTED = TRANSFER_AMOUNT / 10 ** 12;

        console.log("Trasfer Amount Shared Decimals converted:", (TRANSFER_AMOUNT / 10 ** 12));

        console.log("All Chains total supply:", (sepoliaInitialBalance + arbSepoliaInitialBalance) / 10 ** 18, "MOT");

        // Step 2: Perform cross-chain transfer from Sepolia to Arbitrum Sepolia
        vm.createSelectFork(RPC_SEPOLIA);
        vm.startBroadcast(deployerPrivateKey);

        // Convert deployer address to bytes32 format for the destination chain
        bytes32 toAddressBytes32 = bytes32(uint256(uint160(deployer)));

        // Prepare extra options (adapter params)
        // bytes memory extraOptions = bytes("0x");
        bytes memory extraOptions = abi.encodePacked(uint16(1), uint256(200000)); // Version 1, gas limit 200000

        // Get fee estimate using the new simpleQuoteSend function
        MessagingFee memory fee = sepoliaOFTV2Token.simpleQuoteSend(
            ARB_SEPOLIA_LZ_CHAIN_ID, // Destination chain ID
            toAddressBytes32, // Recipient (deployer on Arbitrum Sepolia)
            TRANSFER_AMOUNT, // Amount to transfer
            0,
            extraOptions // Extra options (adapter params)
        );

        // Execute the cross-chain transfer using the new transferCrossChain function
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) = sepoliaOFTV2Token.send{
            value: fee.nativeFee
        }(
            SendParam({
                dstEid: ARB_SEPOLIA_LZ_CHAIN_ID,
                to: toAddressBytes32,
                amountLD: TRANSFER_AMOUNT,
                minAmountLD: 0,
                extraOptions: extraOptions,
                composeMsg: "",
                oftCmd: ""
            }),
            fee,
            msg.sender
        );

        console.log(
            "Cross-chain transfer initiated from Sepolia to Arbitrum Sepolia:", TRANSFER_AMOUNT / 10 ** 18, "MOT"
        );
        console.log("Transfer GUID:", vm.toString(msgReceipt.guid));
        console.log("Amount sent (LD):", oftReceipt.amountSentLD / 10 ** 18);
        console.log("Amount to be received (LD):", oftReceipt.amountReceivedLD / 10 ** 18);

        vm.stopBroadcast();

        // uint256 waitTime = 60; // in seconds
        // console.log("Waiting for", waitTime, "seconds to allow relayer processing...");
        // vm.sleep(waitTime * 1000); // vm.sleep takes milliseconds

        // // Step 3: Fetch balances after transfer (assuming instant processing for simulation)
        // vm.createSelectFork(RPC_SEPOLIA);
        // uint256 sepoliaFinalBalance = sepoliaOFTV2Token.balanceOf(deployer);
        // console.log("Final Sepolia balance of deployer:", sepoliaFinalBalance / 10 ** 18, "MOT");

        // vm.createSelectFork(RPC_ARBITRUM_SEPOLIA);
        // uint256 arbSepoliaFinalBalance = arbSepoliaOFTV2Token.balanceOf(deployer);
        // console.log("Final Arbitrum Sepolia balance of deployer:", arbSepoliaFinalBalance / 10 ** 18, "MOT");
    }
}
