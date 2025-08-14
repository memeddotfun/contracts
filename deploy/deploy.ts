import { readFileSync, writeFileSync } from "node:fs";
import { deployContract, getWallet } from "./utils";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import path from "node:path";

export default async function (hre: HardhatRuntimeEnvironment) {
  const wallet = getWallet();
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
  const factory = await deployContract("MemedFactory_test", [memedBattleAddress, memedEngageToEarnAddress, memedBattleAddress], {
    hre,
    wallet,
    verify: true,
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
