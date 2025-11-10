import { writeFileSync } from "node:fs";

import hre from "hardhat";
import path from "node:path";
import factoryModule from "../ignition/modules/Factory.js";
import battleModule from "../ignition/modules/Battle.js";
import battleResolverModule from "../ignition/modules/BattleResolver.js";
import engageToEarnModule from "../ignition/modules/EngageToEarn.js";
import tokenSaleModule from "../ignition/modules/TokenSale.js";

async function main() {
  const { ignition } = await hre.network.connect();
  
  const uniswapV3PositionManager = "0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2";
  const uniswapV3SwapRouter = "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4";
  const { battle } = await ignition.deploy(battleModule);
  console.log("MemedBattle deployed to:", battle.address);
  const { battleResolver } = await ignition.deploy(battleResolverModule, {
    parameters: {
      BattleResolverModule: {
        battle: battle.address,
      },
    },
  });
  console.log("MemedBattleResolver deployed to:", battleResolver.address);
  const { engageToEarn } = await ignition.deploy(engageToEarnModule);
  console.log("MemedEngageToEarn deployed to:", engageToEarn.address);
  const { tokenSale } = await ignition.deploy(tokenSaleModule);
  console.log("MemedTokenSale deployed to:", tokenSale.address);
  const memedBattleAddress = battle.address;
  const memedBattleResolverAddress = battleResolver.address;
  const memedEngageToEarnAddress = engageToEarn.address;
  const memedTokenSaleAddress = tokenSale.address;
  const { factory } = await ignition.deploy(factoryModule, {
    parameters: {
      FactoryModule: {
        memedTokenSale: memedTokenSaleAddress,
        memedBattle: memedBattleAddress,
        memedEngageToEarn: memedEngageToEarnAddress,
        uniswapV3PositionManager: uniswapV3PositionManager,
        uniswapV3SwapRouter: uniswapV3SwapRouter,
      },
    },
  });
  console.log("MemedFactory deployed to:", factory.address);
  const config = {
    factory: factory.address,
    memedBattle: memedBattleAddress,
    memedBattleResolver: memedBattleResolverAddress,
    memedEngageToEarn: memedEngageToEarnAddress,
    memedTokenSale: memedTokenSaleAddress,
  };


  writeFileSync(path.resolve("../backend/src/config/config.json"), JSON.stringify(config, null, 2));

  // Set factory address in the previously deployed contracts
  console.log("Setting factory and resolver address in MemedBattle...");
  await battle.write.setFactoryAndResolver([config.factory, config.memedBattleResolver]);
  
  console.log("Setting factory address in MemedEngageToEarn...");
  await engageToEarn.write.setFactory([config.factory]);
  
  console.log("Setting factory address in MemedTokenSale...");
  await tokenSale.write.setFactory([config.factory]);
  
  console.log("Deployment completed successfully!");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});