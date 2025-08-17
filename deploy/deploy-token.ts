import { readFileSync, writeFileSync } from "node:fs";
import { deployContract, getWallet } from "./utils";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import path from "node:path";
import axios from "axios";

export default async function (hre: HardhatRuntimeEnvironment) {
  const wallet = getWallet();
  
  // Get name and ticker from command line args
  const args = process.argv.slice(2);
  const name = args[0];
  const ticker = args[1];
  const id = args[2];

  if (!name || !ticker || !id) {
    console.error("Usage: yarn deploy-token <name> <ticker> <id>");
    process.exit(1);
  }
  
  // Get deployed contract addresses from config.json
  const config = JSON.parse(readFileSync(path.resolve("../backend/src/config/config.json"), "utf-8"));
  
  const memedToken = await deployContract("MemedToken", [
    name, 
    ticker, 
    wallet.address, 
    config.factory, 
    config.memedEngageToEarn
  ], {
    hre,
    wallet,
    verify: true,
  });
  const memedTokenAddress = await memedToken.getAddress();
  console.log("MemedToken deployed to:", memedTokenAddress);
  const memedWarriorNFT = await deployContract("MemedWarriorNFT", [memedTokenAddress, config.memedBattle], {
    hre,
    wallet,
    verify: true,
  });
  const memedWarriorNFTAddress = await memedWarriorNFT.getAddress();
  console.log("MemedWarriorNFT deployed to:", memedWarriorNFTAddress);

  // Complete the fair launch
  const factoryContract = await hre.ethers.getContractAt("MemedFactory", config.factory, wallet);
  
  await factoryContract.completeFairLaunch(id, memedTokenAddress, memedWarriorNFTAddress);
  await axios.post(`${process.env.BACKEND_URL}/api/webhook/fair-launch/completed`, {
    id,
    token: memedTokenAddress
  });
  console.log("Fair launch completed successfully!");
}
