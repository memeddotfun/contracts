import { writeFileSync } from "node:fs";

import hre from "hardhat";
import path from "node:path";
import factoryModule from "../ignition/modules/Factory.js";
import battleModule from "../ignition/modules/Battle.js";
import engageToEarnModule from "../ignition/modules/EngageToEarn.js";

export default async function () {
  const connection = await hre.network.connect();
  const uniswapV2Router = "0x6ddD32cd941041D8b61df213B9f515A7D288Dc13";
  const { battle } = await connection.ignition.deploy(battleModule);
  const { engageToEarn } = await connection.ignition.deploy(engageToEarnModule);
  const memedBattleAddress = (battle as any).address as string;
  const memedEngageToEarnAddress = (engageToEarn as any).address as string;
  const { factory } = await connection.ignition.deploy(factoryModule, {
    parameters: {
      memedBattle: memedBattleAddress as any,
      memedEngageToEarn: memedEngageToEarnAddress as any,
      uniswapV2Router: uniswapV2Router as any,
    },
  });
  const config = {
    factory: (factory as any).address,
    memedBattle: memedBattleAddress,
    memedEngageToEarn: memedEngageToEarnAddress,
  };


  writeFileSync(path.resolve("../backend/src/config/config.json"), JSON.stringify(config, null, 2));

  // Set factory address in the previously deployed contracts
  console.log("Setting factory address in MemedBattle...");
  await (battle as any).setFactory(config.factory);
  
  console.log("Setting factory address in MemedEngageToEarn...");
  await (engageToEarn as any).setFactory(config.factory);
  
  console.log("Deployment completed successfully!");
}
