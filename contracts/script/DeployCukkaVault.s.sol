// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CukkaVault} from "../src/CukkaVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BaseSepoliaMorphoBuffer
 * @notice Real ERC-4626 compliant USDC Yield Vault used on Base Sepolia Testnet
 *         to mirror the Base Mainnet Morpho Flagship USDC ERC-4626 Vault (0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca).
 */
contract BaseSepoliaMorphoBuffer is ERC4626 {
    constructor(IERC20 usdc_) ERC4626(usdc_) ERC20("Base Earn Morpho USDC Buffer (Sepolia)", "mUSDC-Sepolia") {}
}

contract DeployCukkaVault is Script {
    // Verified Base Sepolia Circle USDC (6 decimals)
    address public constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    // Verified Base Sepolia Uniswap V3 SwapRouter02
    address public constant BASE_SEPOLIA_ROUTER = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;

    // Verified Base Mainnet Circle USDC (6 decimals)
    address public constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // Verified Base Mainnet Morpho Flagship USDC ERC-4626 Vault
    address public constant BASE_MAINNET_MORPHO_USDC = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;
    // Verified Base Mainnet 1inch / Odos / 0x Aggregator
    address public constant BASE_MAINNET_AGGREGATOR = 0x111111125421cA6dc452d289314280a0f8842A65;

    function run() external returns (CukkaVault vault, address yieldVaultAddr) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address admin = vm.envOr("ADMIN_MULTISIG_ADDRESS", deployer);
        address manager = vm.envOr("MANAGER_ADDRESS", deployer);
        address oracle = vm.envOr("ORACLE_ADDRESS", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT_ADDRESS", deployer);

        vm.startBroadcast(deployerPrivateKey);

        if (block.chainid == 8453) {
            // Base Mainnet
            yieldVaultAddr = BASE_MAINNET_MORPHO_USDC;
            vault = new CukkaVault(
                BASE_MAINNET_USDC,
                yieldVaultAddr,
                BASE_MAINNET_AGGREGATOR,
                admin,
                manager,
                oracle,
                feeRecipient
            );
        } else {
            // Base Sepolia (84532)
            BaseSepoliaMorphoBuffer bufferVault = new BaseSepoliaMorphoBuffer(IERC20(BASE_SEPOLIA_USDC));
            yieldVaultAddr = address(bufferVault);
            vault = new CukkaVault(
                BASE_SEPOLIA_USDC,
                yieldVaultAddr,
                BASE_SEPOLIA_ROUTER,
                admin,
                manager,
                oracle,
                feeRecipient
            );
        }

        vm.stopBroadcast();

        console2.log("Chain ID:", block.chainid);
        console2.log("CukkaVault deployed at:", address(vault));
        console2.log("ERC-4626 Yield Buffer Vault:", yieldVaultAddr);
        console2.log("Admin:", admin);
        console2.log("Manager:", manager);
        console2.log("Oracle:", oracle);
        console2.log("FeeRecipient:", feeRecipient);
    }
}
