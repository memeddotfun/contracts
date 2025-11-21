
# 🧬 Memed.Fun Smart Contracts

**Memed.Fun** is a decentralized meme-token launchpad on the **Base blockchain**, combining **creator tokens**, **NFT battles**, and **engagement-based rewards**.
This repository contains all smart contracts that power the **Memed.Fun ecosystem**.

## ✨ Code Quality

- **Fully documented**: All functions include comprehensive NatSpec comments following Uniswap V3 standards
- **Clean architecture**: Organized structure with separated contracts, interfaces, libraries, and structs
- **Production-ready**: Linter-verified with zero errors
- **Type-safe**: Leverages Solidity 0.8.28 with strict type checking

### Documentation Standards

Every function in the codebase follows this format:

```solidity
/// @notice User-facing description of the function
/// @param _paramName Description of what this parameter does
/// @return Description of what the function returns
function exampleFunction(uint256 _paramName) external returns (uint256) {
    // Clean implementation without inline comments
}
```

**Benefits:**
- ✅ Enhanced code readability and maintainability
- ✅ Auto-generated documentation for developers
- ✅ Better IDE support and tooltips
- ✅ Industry-standard format used by Uniswap, Aave, and other top protocols

---

## 🏗️ Architecture Overview

Memed.Fun consists of **seven interconnected smart contracts** that coordinate token creation, fair launches, NFT battles, and heat-based engagement.

### Core Contracts

| Contract                | Description                                                                                   |
| ----------------------- | --------------------------------------------------------------------------------------------- |
| **MemedFactory**        | Manages meme token creation, heat tracking, Uniswap V3 liquidity, and fair launch completion. |
| **MemedToken**          | ERC20 token implementing Memed’s new v2.3 tokenomics.                                         |
| **MemedTokenSale**      | Fixed-price fair launch system. Handles commit, claim, and cancel.                            |
| **MemedWarriorNFT**     | ERC721 NFT used for battles and meme support.                                                 |
| **MemedBattle**         | Handles on-chain meme vs. meme battles.                                                       |
| **MemedBattleResolver** | Automates battle resolution and updates outcomes.                                             |
| **MemedEngageToEarn**   | Distributes engagement rewards to users and creators.                                         |

---

## 🎯 Key Features

### 🪙 Fixed-Price Fair Launch (No Bonding Curve)

* Each meme token sale happens at a **fixed price**.
* Users commit ETH → receive proportional MEMED tokens.
* Unsold tokens are burned at sale completion.
* Creator allocation handled automatically by `MemedFactory`.
* Sale can be **cancelled** before finalization.
* After completion:

  * 100M MEMED + 39.6 ETH are added to Uniswap V3 LP.
  * 1% post-sale treasury fee is applied.

### 💧 Automatic Uniswap V3 LP

* **100M MEMED (10%) + 39.6 ETH** added to liquidity.
* Uses Uniswap V3 **0.3% fee tier (POOL_FEE = 3000)**.
* Tick range ±10,000 for stable wide liquidity coverage.
* Price ratio precisely encoded via `FullMath` + `TickMath`.
* Validates both token and ETH balances to avoid partial mints.
* LP NFT ID stored via `lpTokenIds[token]` for fee collection.

### 🔥 Heat System

* Heat = meme popularity metric tracked by `updateHeat()`.
* Increases through engagements and battles.
* Unlocks engagement rewards and creator incentives at milestones.
* 1 engagement reward every **50,000 heat** points.

### ⚔️ Battle System

* Meme tokens face off in on-chain duels.
* Winner gains heat + reward unlocks.
* Loser’s unlock threshold increases slightly.
* Battle cooldown: **14 days**.

---

## 📈 Tokenomics (v2.3)

| Allocation              | Tokens | Percentage | Description                       |
| ----------------------- | ------ | ---------- | --------------------------------- |
| **Fair Launch**         | 150M   | 15%        | Fixed-price sale allocation       |
| **Liquidity Pool (LP)** | 100M   | 10%        | Added to Uniswap V3 with 39.6 ETH |
| **Engagement Rewards**  | 550M   | 55%        | Distributed via EngageToEarn      |
| **Creator Incentives**  | 200M   | 20%        | Heat-based unlocks for creators   |
| **Total Supply**        | 1B     | 100%       | Hard-capped supply (no minting)   |

**Solidity constants:**

```solidity
uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1B
uint256 public constant FAIR_LAUNCH_ALLOCATION = 150_000_000 * 1e18; // 15%
uint256 public constant LP_ALLOCATION = 100_000_000 * 1e18; // 10%
uint256 public constant ENGAGEMENT_REWARDS_ALLOCATION = 550_000_000 * 1e18; // 55%
uint256 public constant CREATOR_INCENTIVES_ALLOCATION = 200_000_000 * 1e18; // 20%
```

## 💧 Uniswap V3 LP Model

**Pairing Ratio**

* **100M MEMED tokens**
* **39.6 ETH**

**Core Mechanics**

* Pool created via `IUniswapV3Factory.createPool()`.
* Initialized with encoded sqrt ratio:

  ```solidity
  sqrtPriceX96 = encodeSqrtRatioX96(amount1, amount0);
  ```
* Tick range set to `initialTick ± 10,000` (aligned to 60 tick spacing).
* Full pre-checks ensure both assets exist before mint:

  * `MISSING_TOKEN0` / `MISSING_TOKEN1` reverts if balances are low.
* Reverts gracefully with `MINT_FAILED` on Uniswap position minting errors.

---

## 🧾 Engagement Rewards

| Parameter                              | Value   | Description                          |
| -------------------------------------- | ------- | ------------------------------------ |
| `REWARD_PER_ENGAGEMENT`                | 100,000 | MEMED tokens rewarded per engagement |
| `ENGAGEMENT_REWARDS_PER_NEW_HEAT`      | 50,000  | Heat required for next reward        |
| `MAX_ENGAGE_USER_REWARD_PERCENTAGE`    | 2%      | Max user reward per event            |
| `MAX_ENGAGE_CREATOR_REWARD_PERCENTAGE` | 1%      | Max creator reward per event         |

---

## 📖 Documentation

All contracts follow comprehensive NatSpec documentation standards:

```solidity
/// @notice Brief description of what the function does
/// @dev Additional implementation details (for internal functions)
/// @param paramName Description of parameter
/// @return returnName Description of return value
function exampleFunction(uint256 paramName) external returns (uint256) {
    // Implementation
}
```

**Documentation Coverage:**
- ✅ All 70+ functions across 7 production contracts fully documented
- ✅ Public/external functions include `@notice`, `@param`, and `@return` tags
- ✅ Internal functions include `@dev` implementation details
- ✅ Zero inline comments - clean, self-documenting code

---

## 🔒 Security

* **ReentrancyGuard** — protects `completeFairLaunch`, `claimToken`, etc.
* **Ownable** — only deployer can trigger critical actions.
* **Custom Errors** — readable revert data (`MINT_FAILED`, `NO_LP_BALANCE`, etc.).
* **FullMath + TickMath** — for safe price & ratio calculation.
* **SafeERC20** — prevents unsafe token transfers.

---

## 🧰 Developer Setup

### Requirements

* Node.js ≥ v18
* Yarn or npm
* Hardhat v3 Beta (Ignition)

### Installation

```bash
yarn install
# or
npm install
```

### .env Setup

```env
ALCHEMY_API_KEY=your_alchemy_key
WALLET_KEY=your_private_key
ETHERSCAN_API_KEY=your_etherscan_key
```

---

## ⚙️ Compile

```bash
npx hardhat compile
```

Solidity version:

```ts
solidity: { compilers: [{ version: "0.8.28" }] }
```

All contracts are written in Solidity 0.8.28 with full NatSpec documentation.

---

## 🧪 Testing

```bash
npx hardhat test
```

---

## 🌍 Deployment

### Local Network

```bash
npx hardhat ignition deploy ignition/modules/Factory.ts
```

### Base Sepolia

```bash
npx hardhat ignition deploy --network baseSepolia ignition/modules/Factory.ts
```

### Base Mainnet

```bash
npx hardhat ignition deploy --network base ignition/modules/Factory.ts
```

---

## 📁 Directory Structure

```
contracts/
├── contracts/                    # Main contract implementations
│   ├── MemedFactory.sol         # Core factory contract (fully documented)
│   ├── MemedToken.sol           # ERC20 token implementation
│   ├── MemedTokenSale.sol       # Fair launch sales contract
│   ├── MemedWarriorNFT.sol      # ERC721 NFT for battles
│   ├── MemedBattle.sol          # Battle system contract
│   ├── MemedBattleResolver.sol  # Automated battle resolution
│   ├── MemedEngageToEarn.sol    # Engagement reward distribution
│   ├── MemedFactory_test.sol    # Test version of factory
│   └── MemedTokenSale_test.sol  # Test version of token sale
├── interfaces/                   # Contract interfaces (9 files)
│   ├── IMemedFactory.sol
│   ├── IMemedToken.sol
│   ├── IMemedTokenSale.sol
│   ├── IMemedWarriorNFT.sol
│   ├── IMemedBattle.sol
│   ├── IMemedBattleResolver.sol
│   ├── IMemedEngageToEarn.sol
│   ├── IUniswapV3.sol
│   └── IWETH.sol
├── libraries/                    # Utility libraries
│   ├── TickMath.sol             # Uniswap V3 tick calculations
│   └── FullMath.sol             # 512-bit math operations
├── structs/                      # Data structure definitions (5 files)
│   ├── FactoryStructs.sol
│   ├── TokenSaleStructs.sol
│   ├── EngageToEarnStructs.sol
│   ├── BattleStructs.sol
│   └── WarriorStructs.sol
└── ignition/modules/            # Deployment scripts
    ├── Factory.ts
    ├── TokenSale.ts
    ├── Battle.ts
    └── EngageToEarn.ts
```

**Total Files:**
- 7 Production Contracts (all with comprehensive NatSpec)
- 9 Interface Files  
- 2 Library Files
- 5 Struct Files

---

## ⚖️ Constants Summary

| Variable                          | Value    | Description                     |
| --------------------------------- | -------- | ------------------------------- |
| `POOL_FEE`                        | 3000     | 0.3% Uniswap V3 tier            |
| `LP_ETH()`                        | 39.6 ETH | Fixed ETH paired with LP tokens |
| `BATTLE_REWARDS_PERCENTAGE`       | 20%      | Heat adjustment per battle      |
| `INITIAL_REWARDS_PER_HEAT`        | 100,000  | Default reward threshold        |
| `REWARD_PER_ENGAGEMENT`           | 100,000  | Reward tokens per engagement    |
| `ENGAGEMENT_REWARDS_PER_NEW_HEAT` | 50,000   | Heat per new reward unlock      |

---

## 🌐 Networks

| Network          | Chain ID | RPC                                                                                              | Explorer                                         |
| ---------------- | -------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------ |
| **Base Sepolia** | 84532    | [https://sepolia.base.org](https://sepolia.base.org)                                             | [BaseScan Sepolia](https://sepolia.basescan.org) |
| **Base Mainnet** | 8453     | [https://base-mainnet.g.alchemy.com/v2/YOUR_KEY](https://base-mainnet.g.alchemy.com/v2/YOUR_KEY) | [BaseScan](https://basescan.org)                 |

---

## 🧠 Security Highlights

* Strict validation before every LP mint and heat update.
* LP ticks auto-adjust to valid Uniswap tick spacing.
* Missing ETH or MEMED tokens trigger early revert.
* All external integrations wrapped in `try/catch` with explicit reverts.
* Immutable supply and distribution.

---

## 🤝 Contributing

Pull requests are welcome!
Please ensure:

1. **Code style**: Code is formatted with Prettier
2. **Documentation**: All new functions include NatSpec comments (`@notice`, `@param`, `@return`)
3. **No inline comments**: Use self-documenting code and NatSpec instead
4. **Linter clean**: No linter errors or warnings
5. **Commit messages**: Use short, meaningful commit messages

---

## 📝 License

MIT License © 2025 Memed.Fun

---

## 🛠️ Built With

* **Hardhat 3 (Ignition Beta)**
* **Solidity 0.8.28** with comprehensive NatSpec documentation
* **Uniswap V3 Core & Periphery**
* **OpenZeppelin Contracts v5**
* **Viem + Ethers.js v6**

---

## 📞 Support

* 🌍 [memed.fun](https://memed.fun)
* 🐦 Twitter: [@memedfun](https://twitter.com/memeddotfun)
* 📧 [support@memed.fun](mailto:support@memed.fun)