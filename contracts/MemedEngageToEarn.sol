// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IMemedWarriorNFT {
    function hasActiveWarrior(address user) external view returns (bool);
    function getUserActiveNFTs(address user) external view returns (uint256[] memory);
    function getCurrentPrice() external view returns (uint256);
    function getWarriorMintedBeforeByUser(address _user, uint256 _timestamp) external view returns (uint256);
}

struct TokenBattleAllocation {
    uint256 winCount;
    uint256 loseCount;
}

interface IMemedFactory {
    function getWarriorNFT(address _token) external view returns (address);
    function getMemedBattle() external view returns (address);
    function swap(uint256 _amount, address[] calldata _path, address _to) external returns (uint256[] memory);
}

interface IMemedBattle {
    function tokenBattleAllocations(address _token) external view returns (TokenBattleAllocation memory);
    function getUserTokenBattleAllocations(uint256 _tokenId, uint256 _until) external view returns (TokenBattleAllocation memory);
    function tokenAllocations(address _user) external view returns (uint256[] memory);
}

contract MemedEngageToEarn is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant MAX_REWARD = 350_000_000 * 1e18; // 350M tokens for engagement rewards (v2.3)
    uint256 public constant CYCLE_REWARD_PERCENTAGE = 5; // 5% of engagement rewards per cycle for battles
    uint256 public constant ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE = 20; // 20% of engagement rewards per nft as per their price
    uint256 public constant ENGAGEMENT_REWARDS_CHANGE = 100 *1e18; // engagement rewards change per battle
    IMemedFactory public factory;
    uint256 public engagementRewardId;
    struct EngagementReward {
        address token;
        uint256 amountClaimed;
        uint256 nftPrice;
        uint256 timestamp;
    }

    mapping(uint256 => EngagementReward) public engagementRewards;
    mapping(address => uint256) public totalClaimed;
    mapping(uint256 => mapping(address => bool)) public isClaimedByUser;

    event EngagementRewardRegistered(uint256 indexed rewardId, address indexed token, uint256 nftPrice, uint256 timestamp);
    event EngagementRewardClaimed(address indexed user, uint256 indexed rewardId, uint256 amount);

    function getEngagementReward(uint256 _rewardId) external view returns (EngagementReward memory) {
        return engagementRewards[_rewardId];
    }

    function registerEngagementReward(address _token) external {
        require(msg.sender == address(factory), "Only factory can register engagement rewards");
        uint256 nftPrice = IMemedWarriorNFT(factory.getWarriorNFT(_token)).getCurrentPrice();
        uint256 totalNFTs = IMemedWarriorNFT(factory.getWarriorNFT(_token)).getWarriorMintedBeforeByUser(address(this), block.timestamp);
        TokenBattleAllocation memory tokenBattleAllocation = IMemedBattle(factory.getMemedBattle()).tokenBattleAllocations(_token);
        uint256 change = (ENGAGEMENT_REWARDS_CHANGE * tokenBattleAllocation.winCount) - (ENGAGEMENT_REWARDS_CHANGE * tokenBattleAllocation.loseCount);
        uint256 totalReward =   ((totalNFTs * nftPrice * ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100) + change;
        require(totalReward > 0, "No reward");
        require(totalClaimed[_token] + totalReward <= MAX_REWARD, "Max reward reached");
        totalClaimed[_token] += totalReward;
        engagementRewardId++;
        engagementRewards[engagementRewardId] = EngagementReward(_token, 0, nftPrice, block.timestamp);
        emit EngagementRewardRegistered(engagementRewardId, _token, nftPrice, block.timestamp);
    }

    function claimEngagementReward(uint256 _rewardId) external {
        require(!isClaimedByUser[_rewardId][msg.sender], "Already claimed");
        EngagementReward memory reward = engagementRewards[_rewardId];
        uint256 nftCount = IMemedWarriorNFT(factory.getWarriorNFT(reward.token)).getWarriorMintedBeforeByUser(msg.sender, reward.timestamp);
        uint256[] memory tokenAllocations = IMemedBattle(factory.getMemedBattle()).tokenAllocations(msg.sender);
        uint256 change = 0;
        for (uint256 i = 0; i < tokenAllocations.length; i++) {
            TokenBattleAllocation memory tokenBattleAllocation = IMemedBattle(factory.getMemedBattle()).getUserTokenBattleAllocations(tokenAllocations[i], reward.timestamp);
            change += (ENGAGEMENT_REWARDS_CHANGE * tokenBattleAllocation.winCount) - (ENGAGEMENT_REWARDS_CHANGE * tokenBattleAllocation.loseCount);
        }
        uint256 amount = (((reward.nftPrice * nftCount) * ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100) + change;
        IERC20(reward.token).transfer(msg.sender, amount);
        isClaimedByUser[_rewardId][msg.sender] = true;
        engagementRewards[_rewardId].amountClaimed += amount;
        emit EngagementRewardClaimed(msg.sender, _rewardId, amount);
    }

    /**
     * @dev Get battle reward pool (5% of engagement rewards per cycle)
     */
    function getBattleRewardPool(address _token) external view returns (uint256) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        return (balance * CYCLE_REWARD_PERCENTAGE) / 100;
    }

    function getUserEngagementReward(address _user, address _token) external view returns (uint256) {
        uint256 nftPrice = IMemedWarriorNFT(factory.getWarriorNFT(_token)).getCurrentPrice();
        uint256[] memory tokenAllocations = IMemedBattle(factory.getMemedBattle()).tokenAllocations(_user);
        uint256 change = 0;
        for (uint256 i = 0; i < tokenAllocations.length; i++) {
            TokenBattleAllocation memory tokenBattleAllocation = IMemedBattle(factory.getMemedBattle()).getUserTokenBattleAllocations(tokenAllocations[i], block.timestamp);
            change += (ENGAGEMENT_REWARDS_CHANGE * tokenBattleAllocation.winCount) - (ENGAGEMENT_REWARDS_CHANGE * tokenBattleAllocation.loseCount);
        }
        return ((nftPrice * ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100) + change;
    }
    
    /**
     * @dev Swap tokens to winner (called by battle contract)
     */
    function transferBattleRewards(address _loser, address _winner, uint256 _amount) external returns (uint256) {
        require(msg.sender == address(factory), "Only factory can transfer battle rewards");
        require(IERC20(_loser).balanceOf(address(this)) >= _amount, "Insufficient balance");
        IERC20(_loser).transfer(address(factory), _amount);
        address[] memory path = new address[](2);
        path[0] = _loser;
        path[1] = _winner;
        uint256[] memory amounts = factory.swap(_amount, path, _winner);
        require(amounts[1] > 0, "Swap failed");
        return amounts[1];
    }

    function claimBattleRewards(address _token, address _winner, uint256 _amount) external {
        require(msg.sender == address(factory), "Only factory can transfer battle rewards");
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "Insufficient balance");
        IERC20(_token).transfer(_winner, _amount);
    }

    function setFactory(address _factory) external onlyOwner {
        require(address(factory) == address(0), "Already set");
        factory = IMemedFactory(_factory);
    }
    
    function isRewardable(address _token) external view returns (bool) {
        uint256 totalNFTs = IMemedWarriorNFT(factory.getWarriorNFT(_token)).getWarriorMintedBeforeByUser(address(this), block.timestamp);
        uint256 totalReward = (totalNFTs * IMemedWarriorNFT(factory.getWarriorNFT(_token)).getCurrentPrice() * ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100;
        return totalClaimed[_token] + totalReward <= IERC20(_token).balanceOf(address(this));
    }
}