import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("BattleResolverModule", (m) => {
  const battle = m.getParameter("battle");
  const battleResolver = m.contract("MemedBattleResolver", [battle]);
  return { battleResolver };
});