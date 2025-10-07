import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("FactoryModule", (m) => {
  const memedTokenSale = m.getParameter("memedTokenSale");
  const memedBattle = m.getParameter("memedBattle");
  const memedEngageToEarn = m.getParameter("memedEngageToEarn");
  const uniswapV2Router = m.getParameter("uniswapV2Router");
  const factory = m.contract("MemedFactory_test", [memedTokenSale, memedBattle, memedEngageToEarn, uniswapV2Router]);
  return { factory };
});
