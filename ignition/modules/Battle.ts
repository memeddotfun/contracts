import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("BattleModule", (m) => {
  const battle = m.contract("MemedBattle");
  return { battle };
});
