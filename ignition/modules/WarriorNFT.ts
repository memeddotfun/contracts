import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("WarriorNFTModule", (m) => {
  const memedToken = m.getParameter("token");
  const memedBattle = m.getParameter("battle");
  const factory = m.getParameter("factory");
  const warriorNFT = m.contract("MemedWarriorNFT", [memedToken, memedBattle, factory]);
  return { warriorNFT };
});