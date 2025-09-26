import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("EngageToEarnModule", (m) => {
  const engageToEarn = m.contract("MemedEngageToEarn");
  return { engageToEarn };
});
