import { readFileSync, writeFileSync } from "node:fs";
import { deployContract, getWallet } from "./utils";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import path from "node:path";

export default async function (hre: HardhatRuntimeEnvironment) {
  const wallet = getWallet();
  const uniswapV2Router = hre.network.name == "lensTestnet" ? "0x57a894B5d54658340C50be5B99Fd949b038Ec5DA" : "0x6ddD32cd941041D8b61df213B9f515A7D288Dc13";
  const memedBattle = await deployContract("MemedBattle", [], {
    hre,
    wallet,
    verify: true,
  });
  const memedEngageToEarn = await deployContract("MemedEngageToEarn", [], {
    hre,
    wallet,
    verify: true,
  });
  const memedBattleAddress = await memedBattle.getAddress();
  const memedEngageToEarnAddress = await memedEngageToEarn.getAddress();
  const factory = await deployContract("MemedFactory_test", [memedBattleAddress, memedEngageToEarnAddress, uniswapV2Router], {
    hre,
    wallet,
    verify: false,
  });
  const config = {
    factory: await factory.getAddress(),
    memedBattle: memedBattleAddress,
    memedEngageToEarn: memedEngageToEarnAddress,
  };


  writeFileSync(path.resolve("../backend/src/config/config.json"), JSON.stringify(config, null, 2));

  // Set factory address in the previously deployed contracts
  console.log("Setting factory address in MemedBattle...");
  await memedBattle.setFactory(config.factory);
  
  console.log("Setting factory address in MemedEngageToEarn...");
  await memedEngageToEarn.setFactory(config.factory);
  
  console.log("Deployment completed successfully!");
}
