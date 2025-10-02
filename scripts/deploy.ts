import { writeFileSync } from "node:fs";

import hre from "hardhat";
import path from "node:path";
import factoryModule from "../ignition/modules/Factory.js";
import battleModule from "../ignition/modules/Battle.js";
import engageToEarnModule from "../ignition/modules/EngageToEarn.js";
import tokenSaleModule from "../ignition/modules/TokenSale.js";

async function main() {
  const { ignition, id } = await hre.network.connect();
  
  const uniswapV2Router = id === 0 ? "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4" : "0x2626664c2603336E57B271c5C0b26F421741e481";
  const { battle } = await ignition.deploy(battleModule);
  const { engageToEarn } = await ignition.deploy(engageToEarnModule);
  const { tokenSale } = await ignition.deploy(tokenSaleModule);
  const memedBattleAddress = battle.address;
  const memedEngageToEarnAddress = engageToEarn.address;
  const memedTokenSaleAddress = tokenSale.address;
  const { factory } = await ignition.deploy(factoryModule, {
    parameters: {
      FactoryModule: {
        memedTokenSale: memedTokenSaleAddress,
        memedBattle: memedBattleAddress,
        memedEngageToEarn: memedEngageToEarnAddress,
        uniswapV2Router: uniswapV2Router,
      },
    },
  });
  const config = {
    factory: factory.address,
    memedBattle: memedBattleAddress,
    memedEngageToEarn: memedEngageToEarnAddress,
    memedTokenSale: memedTokenSaleAddress,
  };


  writeFileSync(path.resolve("../backend/src/config/config.json"), JSON.stringify(config, null, 2));

  // Set factory address in the previously deployed contracts
  console.log("Setting factory address in MemedBattle...");
  await battle.write.setFactory([config.factory]);
  
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