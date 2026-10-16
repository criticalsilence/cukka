import { createConfig } from "@ponder/core";
import { http } from "viem";
import { CukkaVaultAbi } from "./abis/CukkaVaultAbi";
import { ERC20Abi } from "./abis/ERC20Abi";

export default createConfig({
  networks: {
    baseSepolia: {
      chainId: 84532,
      transport: http(process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org"),
    },
  },
  contracts: {
    CukkaVault: {
      network: "baseSepolia",
      abi: CukkaVaultAbi,
      address: (process.env.NEXT_PUBLIC_CUKKA_VAULT_ADDRESS as `0x${string}`) || "0xfBf0490B3063fBb5cA7B995c8CC1e295C41Db761",
      startBlock: 21500000,
    },
    CircleUSDC: {
      network: "baseSepolia",
      abi: ERC20Abi,
      address: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
      startBlock: 21500000,
    },
  },
});
