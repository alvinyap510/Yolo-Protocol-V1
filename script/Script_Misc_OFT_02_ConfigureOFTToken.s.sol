// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "@yolo/contracts/mocks/OFTV2Token.sol";

contract Script_Misc_OFT_02_ConfigureOFTToken is Script {
    address constant lzEndpoint = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    uint16 constant SEPOLIA_LZ_CHAIN_ID = 40161;
    uint16 constant ARB_SEPOLIA_LZ_CHAIN_ID = 40231;

    // Hardcode the deployed addresses from the previous step
    address constant SEPOLIA_OFT_ADDRESS = 0x48AAd4E5E88C0fc956C7FF9f6a4E747f759F8815;
    address constant ARB_SEPOLIA_OFT_ADDRESS = 0x4F412844eA94Be760B72e02973Aa1d0a74a5D6F1;

    function run() external {
        string memory RPC_SEPOLIA = vm.envString("RPC_SEPOLIA");
        string memory RPC_ARBITRUM_SEPOLIA = vm.envString("RPC_ARBITRUM_SEPOLIA");

        uint256 deployerPrivateKey = vm.envUint("TEST_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployer);

        // Set peer: Sepolia -> Arbitrum Sepolia
        vm.createSelectFork(RPC_SEPOLIA);
        vm.startBroadcast(deployerPrivateKey);
        OFTV2Token sepoliaOFTV2Token = OFTV2Token(SEPOLIA_OFT_ADDRESS);
        sepoliaOFTV2Token.setPeer(ARB_SEPOLIA_LZ_CHAIN_ID, bytes32(uint256(uint160(ARB_SEPOLIA_OFT_ADDRESS))));
        console.log("Sepolia peer set to Arbitrum Sepolia:", ARB_SEPOLIA_OFT_ADDRESS);
        vm.stopBroadcast();

        // Set peer: Arbitrum Sepolia -> Sepolia
        vm.createSelectFork(RPC_ARBITRUM_SEPOLIA);
        vm.startBroadcast(deployerPrivateKey);
        OFTV2Token arbSepoliaOFTV2Token = OFTV2Token(ARB_SEPOLIA_OFT_ADDRESS);
        arbSepoliaOFTV2Token.setPeer(SEPOLIA_LZ_CHAIN_ID, bytes32(uint256(uint160(SEPOLIA_OFT_ADDRESS))));
        console.log("Arbitrum Sepolia peer set to Sepolia:", SEPOLIA_OFT_ADDRESS);
        vm.stopBroadcast();
    }
}
