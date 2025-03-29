// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "@yolo/contracts/mocks/OFTV2Token.sol";

contract Script_Misc_OFT_01_DeployOFTToken is Script {
    address constant lzEndpoint = 0x6EDCE65403992e310A62460808c4b910D972f10f; // LayerZero endpoint
    uint256 constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 constant ARB_SEPOLIA_CHAIN_ID = 421614;

    OFTV2Token public sepoliaOFTV2Token;
    OFTV2Token public arbSepoliaOFTV2Token;

    function run() external {
        string memory RPC_SEPOLIA = vm.envString("RPC_SEPOLIA");
        string memory RPC_ARBITRUM_SEPOLIA = vm.envString("RPC_ARBITRUM_SEPOLIA");

        // Load deployer
        uint256 deployerPrivateKey = vm.envUint("TEST_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployer);

        // Log balances
        vm.createSelectFork(RPC_SEPOLIA);
        console.log("Deployer balance on Sepolia:", deployer.balance);
        vm.createSelectFork(RPC_ARBITRUM_SEPOLIA);
        console.log("Deployer balance on Arbitrum Sepolia:", deployer.balance);

        // Deploy on Sepolia
        vm.createSelectFork(RPC_SEPOLIA);
        console.log();
        vm.startBroadcast(deployerPrivateKey);
        sepoliaOFTV2Token = new OFTV2Token("My OFT Token", "MOT", lzEndpoint);
        console.log("Sepolia Token deployed at:", address(sepoliaOFTV2Token));
        console.log("Sepolia Chain ID:", block.chainid);
        vm.stopBroadcast();

        // Deploy on Arbitrum Sepolia
        vm.createSelectFork(RPC_ARBITRUM_SEPOLIA);
        console.log();
        vm.startBroadcast(deployerPrivateKey);
        arbSepoliaOFTV2Token = new OFTV2Token("My OFT Token", "MOT", lzEndpoint);
        console.log("Arbitrum Sepolia Token deployed at:", address(arbSepoliaOFTV2Token));
        console.log("Arbitrum Sepolia Chain ID:", block.chainid);
        vm.stopBroadcast();
    }
}
