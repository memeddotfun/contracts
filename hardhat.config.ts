import "@matterlabs/hardhat-zksync";
import "@matterlabs/hardhat-zksync-verify";

import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-solhint";

import { HardhatUserConfig } from "hardhat/config";

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
