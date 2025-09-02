import "@matterlabs/hardhat-zksync";
import "@matterlabs/hardhat-zksync-verify";

import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-solhint";

import { HardhatUserConfig, task } from "hardhat/config";


task("deploy-token", "Deploy Memed Token")
  .addParam("creator", "Token creator")
  .addParam("name", "Token name")
  .addParam("ticker", "Token ticker")
  .addParam("id", "Fair launch ID")
  .setAction(async (args, hre) => {
    const { default: deployToken } = await import("./deploy/deploy-token");
    await deployToken(hre, args.creator, args.name, args.ticker, args.id);
  });
const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
  },
  zksolc: {
    version: "1.5.3",
    settings: {},
  },
  networks: {
    lensTestnet: {
      chainId: 37111,
      url: "https://api.staging.lens.zksync.dev",
      verifyURL:
        "https://api-explorer-verify.staging.lens.zksync.dev/contract_verification",
      zksync: true,
      ethNetwork: "sepolia",
    },
    hardhat: {
      loggingEnabled: true,
      zksync: true,
    },
    mainnet: {
      chainId: 232,
      url: "https://rpc.lens.xyz",
    },
  },
};

export default config;
