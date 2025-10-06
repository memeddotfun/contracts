import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("TokenModule", (m) => {
  const name = m.getParameter("name");
  const ticker = m.getParameter("ticker");
  const creator = m.getParameter("creator");
  const factoryContract = m.getParameter("factoryContract");
  const engageToEarnContract = m.getParameter("engageToEarnContract");
  const lpSupply = m.getParameter("lpSupply");
  const token = m.contract("MemedToken", [name, ticker, creator, factoryContract, engageToEarnContract, lpSupply]);
  return { token };
});
