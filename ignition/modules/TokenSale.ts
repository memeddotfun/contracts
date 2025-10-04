import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("TokenSaleModule", (m) => {
  const tokenSale = m.contract("MemedTokenSale");
  return { tokenSale };
});
