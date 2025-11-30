import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("FactoryModule", (m) => {
  const memedTokenSale = m.getParameter("memedTokenSale");
  const memedBattle = m.getParameter("memedBattle");
  const memedEngageToEarn = m.getParameter("memedEngageToEarn");
  const uniswapV3PositionManager = m.getParameter("uniswapV3PositionManager");
  const uniswapV3SwapRouter = m.getParameter("uniswapV3SwapRouter");
  const factory = m.contract("MemedFactory", [memedTokenSale, memedBattle, memedEngageToEarn, uniswapV3PositionManager, uniswapV3SwapRouter]);
  return { factory };
});
