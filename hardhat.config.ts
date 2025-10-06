import type { HardhatUserConfig } from "hardhat/config";

import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import hardhatVerifyPlugin from "@nomicfoundation/hardhat-verify";
import hardhatKeystorePlugin from "@nomicfoundation/hardhat-keystore";
import { configVariable } from "hardhat/config";


const WALLET_KEY = configVariable("WALLET_KEY");
const ALCHEMY_API_KEY = configVariable("ALCHEMY_API_KEY");
const ETHERSCAN_API_KEY = configVariable("ETHERSCAN_API_KEY");


const config: HardhatUserConfig = {
  plugins: [hardhatToolboxViemPlugin, hardhatKeystorePlugin, hardhatVerifyPlugin],
  solidity: {
    version: "0.8.28",
  },
  networks: {
    base: {
      type: "http",
      url: `https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [WALLET_KEY || ""],
      chainId: 8453,
    },
    baseSepolia: {
      type: "http",
      url: `https://sepolia.base.org`,
      accounts: [WALLET_KEY || ""],
      chainId: 84532,
    },
  },
  verify: {
  etherscan: {
    apiKey: ETHERSCAN_API_KEY,
  },
  },
};

export default config;
