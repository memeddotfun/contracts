import { readFileSync } from "node:fs";
import { deployContract, getWallet } from "./utils";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import path from "node:path";

export default async function (
  hre: HardhatRuntimeEnvironment,
  creator: string,
  name: string,
  ticker: string,
  id: string
) {
  const wallet = getWallet();

  if (!name || !ticker || !id) {
    throw new Error("Missing params: name, ticker, id");
  }

  const configPath = path.resolve("../backend/src/config/config.json");
  const config = JSON.parse(readFileSync(configPath, "utf-8"));
  const memedToken = await deployContract(
    "MemedToken",
    [name, ticker, creator, config.factory, config.memedEngageToEarn],
    { hre, wallet, verify: true }
  );
  const memedTokenAddress = await memedToken.getAddress();
  console.log("MemedToken deployed to:", memedTokenAddress);

  const memedWarriorNFT = await deployContract(
    "MemedWarriorNFT",
    [memedTokenAddress, config.factory, config.memedBattle],
    { hre, wallet, verify: true }
  );
  const memedWarriorNFTAddress = await memedWarriorNFT.getAddress();
  console.log("MemedWarriorNFT deployed to:", memedWarriorNFTAddress);

  const factoryContract = await hre.ethers.getContractAt(
    "MemedFactory",
    config.factory,
    wallet
  );

  await factoryContract.completeFairLaunch(id, memedTokenAddress, memedWarriorNFTAddress);
  console.log("Fair launch completed successfully!");
}
