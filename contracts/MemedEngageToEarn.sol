// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IMemedWarriorNFT.sol";
import "../interfaces/IMemedFactory.sol";
import "../interfaces/IMemedBattle.sol";
import "../structs/BattleStructs.sol";
import "../structs/EngageToEarnStructs.sol";

contract MemedEngageToEarn is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public constant MAX_REWARD = 500_000_000 * 1e18; // 500M tokens for engagement rewards (v2.3)
    uint256 public constant CYCLE_REWARD_PERCENTAGE = 5; // 5% of engagement rewards per cycle for battles
    uint256 public constant ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE = 20; // 20% of engagement rewards per nft as per their price
    uint256 public constant ENGAGEMENT_REWARDS_CHANGE = 100 *1e18; // engagement rewards change per battle
    IMemedFactory public factory;
    uint256 public engagementRewardId;

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
        uint256 totalNFTs = IMemedWarriorNFT(factory.getWarriorNFT(_token)).currentTokenId();
        TokenBattleAllocation memory tokenBattleAllocation = IMemedBattle(factory.getMemedBattle()).tokenBattleAllocations(_token);
        uint256 change = tokenBattleAllocation.winCount > tokenBattleAllocation.loseCount 
            ? (ENGAGEMENT_REWARDS_CHANGE * (tokenBattleAllocation.winCount - tokenBattleAllocation.loseCount))
            : 0;
        uint256 totalReward = ((totalNFTs * nftPrice * ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100) + change;
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
        require(reward.token != address(0), "Reward does not exist");
        
        uint256 nftCount = IMemedWarriorNFT(factory.getWarriorNFT(reward.token)).getWarriorMintedBeforeByUser(msg.sender, reward.timestamp);
        uint256[] memory tokenAllocationsArray = IMemedBattle(factory.getMemedBattle()).getUserTokenAllocations(msg.sender);
        uint256 change = 0;
        for (uint256 i = 0; i < tokenAllocationsArray.length; i++) {
            TokenBattleAllocation memory tokenBattleAllocation = IMemedBattle(factory.getMemedBattle()).getUserTokenBattleAllocations(tokenAllocationsArray[i], reward.timestamp);
            if (tokenBattleAllocation.winCount > tokenBattleAllocation.loseCount) {
                change += ENGAGEMENT_REWARDS_CHANGE * (tokenBattleAllocation.winCount - tokenBattleAllocation.loseCount);
            }
        }
        uint256 amount = (((reward.nftPrice * nftCount) * ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100) + change;
        require(amount > 0, "No reward to claim");
        
        isClaimedByUser[_rewardId][msg.sender] = true;
        engagementRewards[_rewardId].amountClaimed += amount;
        IERC20(reward.token).transfer(msg.sender, amount);
        emit EngagementRewardClaimed(msg.sender, _rewardId, amount);
    }

    /**
     * @dev Get battle reward pool (5% of engagement rewards per cycle)
     */
    function getBattleRewardPool(address _token) external view returns (uint256) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        return (balance * CYCLE_REWARD_PERCENTAGE) / 100;
    }

    function getUserEngagementReward() public view returns (EngagementRewardClaim[] memory) {
        // First pass: count valid claims
        uint256 validClaimCount = 0;
        for (uint256 i = 1; i <= engagementRewardId; i++) {
            if (!isClaimedByUser[i][msg.sender] && engagementRewards[i].token != address(0)) {
                validClaimCount++;
            }
        }
        
        EngagementRewardClaim[] memory engagementRewardsClaims = new EngagementRewardClaim[](validClaimCount);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= engagementRewardId; i++) {
            if (isClaimedByUser[i][msg.sender]) {
                continue; // Skip already claimed rewards
            }
            
            EngagementReward memory reward = engagementRewards[i];
            if (reward.token == address(0)) {
                continue; // Skip invalid rewards
            }
            
            // Get NFT count minted before reward timestamp
            uint256 nftCount = IMemedWarriorNFT(factory.getWarriorNFT(reward.token)).getWarriorMintedBeforeByUser(msg.sender, reward.timestamp);
            
            // Calculate battle-based change rewards
            uint256[] memory tokenAllocationsArray = IMemedBattle(factory.getMemedBattle()).getUserTokenAllocations(msg.sender);
            uint256 change = 0;
            for (uint256 j = 0; j < tokenAllocationsArray.length; j++) {
                TokenBattleAllocation memory tokenBattleAllocation = IMemedBattle(factory.getMemedBattle()).getUserTokenBattleAllocations(tokenAllocationsArray[j], reward.timestamp);
                if (tokenBattleAllocation.winCount > tokenBattleAllocation.loseCount) {
                    change += ENGAGEMENT_REWARDS_CHANGE * (tokenBattleAllocation.winCount - tokenBattleAllocation.loseCount);
                }
            }
            
            // Calculate total reward amount
            uint256 amount = (((reward.nftPrice * nftCount) * ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100) + change;
            
            engagementRewardsClaims[index] = EngagementRewardClaim(msg.sender, i, amount, reward.token);
            index++;
        }
        
        return engagementRewardsClaims;
    }

    /**
     * @dev Batch claim multiple engagement rewards
     * @param _rewardIds Array of reward IDs to claim
     */
    function batchClaimEngagementRewards(uint256[] calldata _rewardIds) external {
        require(_rewardIds.length > 0, "No reward IDs provided");
        require(_rewardIds.length <= 50, "Too many rewards to claim at once"); // Prevent gas limit issues
        
        for (uint256 i = 0; i < _rewardIds.length; i++) {
            uint256 _rewardId = _rewardIds[i];
            
            // Skip if already claimed
            if (isClaimedByUser[_rewardId][msg.sender]) {
                continue;
            }
            
            EngagementReward memory reward = engagementRewards[_rewardId];
            
            // Skip if reward doesn't exist
            if (reward.token == address(0)) {
                continue;
            }
            
            // Get NFT count minted before reward timestamp
            uint256 nftCount = IMemedWarriorNFT(factory.getWarriorNFT(reward.token)).getWarriorMintedBeforeByUser(msg.sender, reward.timestamp);
            
            // Calculate battle-based change rewards
            uint256[] memory tokenAllocationsArray = IMemedBattle(factory.getMemedBattle()).getUserTokenAllocations(msg.sender);
            uint256 change = 0;
            for (uint256 j = 0; j < tokenAllocationsArray.length; j++) {
                TokenBattleAllocation memory tokenBattleAllocation = IMemedBattle(factory.getMemedBattle()).getUserTokenBattleAllocations(tokenAllocationsArray[j], reward.timestamp);
                if (tokenBattleAllocation.winCount > tokenBattleAllocation.loseCount) {
                    change += ENGAGEMENT_REWARDS_CHANGE * (tokenBattleAllocation.winCount - tokenBattleAllocation.loseCount);
                }
            }
            
            // Calculate total amount
            uint256 amount = (((reward.nftPrice * nftCount) * ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100) + change;
            
            // Skip if no reward to claim
            if (amount == 0) {
                continue;
            }
            
            // Mark as claimed
            isClaimedByUser[_rewardId][msg.sender] = true;
            engagementRewards[_rewardId].amountClaimed += amount;
            
            // Transfer tokens
            IERC20(reward.token).transfer(msg.sender, amount);
            
            emit EngagementRewardClaimed(msg.sender, _rewardId, amount);
        }
    }
    
    /**
     * @dev Swap loser tokens to winner tokens for battle rewards
     * @param _loser Loser token address (token to swap from)
     * @param _winner Winner token address (token to swap to)
     * @param _loserAmount Amount of loser tokens to swap
     */
    function transferBattleRewards(address _loser, address _winner, uint256 _loserAmount) external returns (uint256) {
        require(msg.sender == IMemedBattle(factory.getMemedBattle()).getResolver(), "Only resolver can transfer battle rewards");
        require(IERC20(_loser).balanceOf(address(this)) >= _loserAmount, "Insufficient loser token balance");
        
        // Transfer loser tokens to factory for swap
        IERC20(_loser).transfer(address(factory), _loserAmount);
        
        // Swap loser tokens to winner tokens
        address[] memory path = new address[](2);
        path[0] = _loser;
        path[1] = _winner;
        uint256 amountOut = factory.swap(_loserAmount, path, address(this));
        
        require(amountOut > 0, "Swap failed");
        return amountOut;
    }

    function claimBattleRewards(address _token, address _winner, uint256 _amount) external {
        require(msg.sender == factory.getMemedBattle(), "Only battle can transfer battle rewards");
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "Insufficient balance");
        IERC20(_token).transfer(_winner, _amount);
    }

    function setFactory(address _factory) external onlyOwner {
        require(address(factory) == address(0), "Already set");
        factory = IMemedFactory(_factory);
    }
    
    function isRewardable(address _token) external view returns (bool) {
        uint256 totalNFTs = IMemedWarriorNFT(factory.getWarriorNFT(_token)).currentTokenId();
        if (totalNFTs == 0) return false;
        uint256 totalReward = (totalNFTs * IMemedWarriorNFT(factory.getWarriorNFT(_token)).getCurrentPrice() * ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100;
        return totalClaimed[_token] + totalReward <= IERC20(_token).balanceOf(address(this));
    }
}