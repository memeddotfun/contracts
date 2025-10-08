# Memed.Fun Smart Contracts

Memed.Fun is a decentralized meme token platform built on Base blockchain that combines fair launches, NFT battles, and engagement-based rewards. This repository contains all the core smart contracts that power the Memed.Fun ecosystem.

## 🏗️ Architecture Overview

The Memed.Fun platform consists of seven interconnected smart contracts:

### Core Contracts

1. **MemedFactory** - Central hub managing token creation, heat scoring, and fair launches
2. **MemedToken** - ERC20 token with custom tokenomics and vesting schedules
3. **MemedTokenSale** - Fair launch mechanism with bonding curve pricing
4. **MemedWarriorNFT** - ERC721 NFTs used for battle participation
5. **MemedBattle** - Battle system where tokens compete for rewards
6. **MemedBattleResolver** - Automated battle resolution logic
7. **MemedEngageToEarn** - Engagement rewards distribution system

## 🎯 Key Features

### Fair Launch Mechanism
- Bonding curve-based token sales
- 200M tokens (20%) allocated for fair launch
- Initial creator allocation of 50M tokens (5%)
- Automatic LP creation on Uniswap V2

### Heat Score System
- Dynamic scoring based on engagement metrics
- Unlocks creator incentives at milestones
- Affects NFT minting prices
- Influences battle rewards

### NFT Battle System
- 14-day battle cooldown between challenges
- Stake Warrior NFTs to support your favorite memes
- Winners claim rewards from the prize pool
- Dynamic NFT pricing: `5,000 MEME + (100 MEME × (Total Heat Score ÷ 10,000))`

### Tokenomics
- **Total Supply**: 700M + LP allocation
- **Fair Launch**: 200M (20%)
- **Liquidity Pool**: 250M (25%)
- **Engagement Rewards**: 350M (35%)
- **Creator Incentives**: 150M (15%)
- **Creator Initial**: 50M (5%)

### Engagement Rewards
- 100,000 tokens per engagement reward
- Users earn up to 2% per engagement
- Creators earn up to 1% per engagement
- New rewards unlock every 50,000 heat points

## 📋 Prerequisites

- [Node.js](https://nodejs.org/) (v18 or higher)
- [Yarn](https://yarnpkg.com/) or [npm](https://www.npmjs.com/)
- [Hardhat](https://hardhat.org/)

## 🚀 Getting Started

### Installation

```bash
# Install dependencies
yarn install
# or
npm install
```

### Environment Setup

Create a `.env` file in the root directory:

```env
ALCHEMY_API_KEY=your_alchemy_api_key
WALLET_KEY=your_private_key
ETHERSCAN_API_KEY=your_etherscan_api_key
```

### Compilation

```bash
# Compile all contracts
npx hardhat compile
```

### Testing

```bash
# Run all tests
npx hardhat test

# Run Solidity tests only
npx hardhat test solidity

# Run Node.js tests only
npx hardhat test nodejs
```

## 🌐 Deployment

### Local Deployment

```bash
# Deploy to local hardhat network
npx hardhat ignition deploy ignition/modules/Factory.ts
```

### Base Sepolia (Testnet)

```bash
# Deploy to Base Sepolia testnet
npx hardhat ignition deploy --network baseSepolia ignition/modules/Factory.ts
```

### Base Mainnet

```bash
# Deploy to Base mainnet
npx hardhat ignition deploy --network base ignition/modules/Factory.ts
```

## 📁 Project Structure

```
contracts/
├── contracts/
│   ├── MemedFactory.sol          # Main factory contract
│   ├── MemedToken.sol             # ERC20 token implementation
│   ├── MemedTokenSale.sol         # Fair launch mechanism
│   ├── MemedWarriorNFT.sol        # ERC721 NFT contract
│   ├── MemedBattle.sol            # Battle system
│   ├── MemedBattleResolver.sol    # Battle resolution
│   └── MemedEngageToEarn.sol      # Engagement rewards
├── interfaces/                     # Contract interfaces
│   ├── IMemedFactory.sol
│   ├── IMemedToken.sol
│   ├── IMemedTokenSale.sol
│   ├── IMemedWarriorNFT.sol
│   ├── IMemedBattle.sol
│   ├── IMemedBattleResolver.sol
│   ├── IMemedEngageToEarn.sol
│   └── IUniswapV2.sol
├── structs/                        # Data structures
│   ├── FactoryStructs.sol
│   ├── TokenStructs.sol
│   ├── TokenSaleStructs.sol
│   ├── WarriorStructs.sol
│   ├── BattleStructs.sol
│   └── EngageToEarnStructs.sol
├── ignition/modules/              # Deployment scripts
│   ├── Factory.ts
│   ├── TokenSale.ts
│   ├── Battle.ts
│   ├── BattleResolver.ts
│   └── EngageToEarn.ts
└── test/                          # Test files
```

## 🔧 Contract Interactions

### Creating a New Token

```solidity
// Call through MemedFactory
factory.startFairLaunch(
    creatorAddress,
    "Token Name",
    "TICKER",
    "Description",
    "ipfs://image-hash"
);
```

### Minting Warrior NFTs

```solidity
// Calculate current price
uint256 price = warriorNFT.getCurrentPrice();

// Approve MEME tokens
memedToken.approve(address(warriorNFT), price);

// Mint NFT
uint256 tokenId = warriorNFT.mintWarrior();
```

### Starting a Battle

```solidity
// Challenge another token
battle.challengeBattle(memeTokenA, memeTokenB);

// Accept challenge (if required)
battle.acceptBattle(battleId);

// Allocate NFTs to support a side
warriorNFT.allocateNFTsToBattle(battleId, user, supportedMeme, nftIds);
```

## 🔐 Security Features

- **ReentrancyGuard** - Protection against reentrancy attacks
- **Ownable** - Access control for administrative functions
- **SafeERC20** - Safe token transfers
- **Nonreentrant modifiers** - On all external state-changing functions
- **Pausable mechanisms** - Emergency stop functionality

## 🌟 Key Constants

### Battle System
- `BATTLE_COOLDOWN`: 14 days
- `BATTLE_REWARDS_PERCENTAGE`: 20%
- `INITIAL_REWARDS_PER_HEAT`: 100,000

### NFT Pricing
- `BASE_PRICE`: 5,000 MEME tokens
- `PRICE_INCREMENT`: 100 MEME per 10,000 heat
- `HEAT_THRESHOLD`: 10,000

### Engagement
- `REWARD_PER_ENGAGEMENT`: 100,000 tokens
- `MAX_ENGAGE_USER_REWARD_PERCENTAGE`: 2%
- `MAX_ENGAGE_CREATOR_REWARD_PERCENTAGE`: 1%
- `ENGAGEMENT_REWARDS_PER_NEW_HEAT`: 50,000

## 📜 Networks

### Base Sepolia Testnet
- **Chain ID**: 84532
- **RPC**: https://sepolia.base.org
- **Explorer**: https://sepolia.basescan.org

### Base Mainnet
- **Chain ID**: 8453
- **RPC**: https://base-mainnet.g.alchemy.com/v2/YOUR_API_KEY
- **Explorer**: https://basescan.org

## 🤝 Contributing

Contributions are welcome! Please ensure all tests pass before submitting a PR.

## 📝 License

This project is licensed under the MIT License.

## 🛠️ Built With

- [Hardhat 3 Beta](https://hardhat.org/) - Development environment
- [Viem](https://viem.sh/) - TypeScript interface for Ethereum
- [OpenZeppelin](https://openzeppelin.com/contracts/) - Secure smart contract library
- [Solidity ^0.8.28](https://soliditylang.org/) - Smart contract language

## 📞 Support

For questions and support, please join our community or open an issue in this repository.

---

**Note**: This project uses Hardhat 3 Beta. To learn more, visit the [Hardhat documentation](https://hardhat.org/docs/getting-started).
