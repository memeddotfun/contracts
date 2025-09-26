import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("FactoryModule", (m) => {
  const memedBattle = m.getParameter("memedBattle");
  const memedEngageToEarn = m.getParameter("memedEngageToEarn");
  const uniswapV2Router = m.getParameter("uniswapV2Router");
  const factory = m.contract("MemedFactory", [memedBattle, memedEngageToEarn, uniswapV2Router]);
  return { factory };
});
