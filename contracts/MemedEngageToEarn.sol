// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IMemedWarriorNFT.sol";
import "../interfaces/IMemedFactory.sol";
import "../interfaces/IMemedBattle.sol";
import "../structs/BattleStructs.sol";
import "../structs/EngageToEarnStructs.sol";

contract MemedEngageToEarn is Ownable, ReentrancyGuard {
    constructor() Ownable(msg.sender) {}

    uint256 public constant MAX_REWARD = 550_000_000 * 1e18; // 550M tokens for engagement rewards (v2.3)
    uint256 public constant MAX_REWARD_PER_DAY = 5000000 * 1e18; // 5M tokens for each day (v2.4)
    uint256 public constant CYCLE_REWARD_PERCENTAGE = 5; // 5% of engagement rewards per cycle for battles
    uint256 public constant ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE = 20; // 20% of engagement rewards per nft as per their price
    uint256 public constant ENGAGEMENT_REWARDS_CHANGE = 100 * 1e18; // engagement rewards change per battle
    uint256 public constant CREATOR_INCENTIVES_ALLOCATION = 200000000 * 1e18; // 200M (20%)
    uint256 public constant CREATOR_ALLOCATION_PER_UNLOCK = 5000000 * 1e18; // 5M tokens
    IMemedFactory public factory;
    uint256 public engagementRewardId;

    mapping(uint256 => EngagementReward) public engagementRewards;
    mapping(address => uint256) public totalClaimed;
    mapping(address => DayData) public dayData;
    mapping(uint256 => mapping(address => bool)) public isClaimedByUser;
    mapping(address => CreatorData) public creatorData;
    event EngagementRewardRegistered(
        uint256 indexed rewardId,
        address indexed token,
        uint256 nftPrice,
        uint256 timestamp
    );
    event EngagementRewardClaimed(
        address indexed user,
        uint256 indexed rewardId,
        uint256 amount
    );
    event CreatorIncentivesUnlocked(uint256 amount);
    event CreatorIncentivesClaimed(uint256 amount);
    event CreatorSet(address to);

    function getEngagementReward(
        uint256 _rewardId
    ) external view returns (EngagementReward memory) {
        return engagementRewards[_rewardId];
    }

    function registerEngagementReward(address _token) external {
        require(
            msg.sender == address(factory),
            "Only factory can register engagement rewards"
        );

        address warrior = factory.getWarriorNFT(_token);
        uint256 nftPrice = IMemedWarriorNFT(warrior).getCurrentPrice();
        uint256 totalNFTs = IMemedWarriorNFT(warrior).currentTokenId();

        TokenBattleAllocation memory alloc = IMemedBattle(
            factory.getMemedBattle()
        ).tokenBattleAllocations(_token);

        uint256 change = alloc.winCount > alloc.loseCount
            ? (ENGAGEMENT_REWARDS_CHANGE * (alloc.winCount - alloc.loseCount))
            : 0;

        if (block.timestamp > dayData[_token].timestamp + 1 days) {
            dayData[_token].timestamp = block.timestamp;
            dayData[_token].amountClaimed = 0;
        }

        uint256 perNftReward = (nftPrice *
            ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100;
        require(perNftReward > 0, "Invalid reward");

        uint256 remainingDayCap = MAX_REWARD_PER_DAY -
            dayData[_token].amountClaimed;
        require(remainingDayCap > 0, "Daily cap reached");

        uint256 maxNFTsByCap = remainingDayCap / perNftReward;
        uint256 rewardableNFTs = totalNFTs < maxNFTsByCap
            ? totalNFTs
            : maxNFTsByCap;

        uint256 nftReward = (rewardableNFTs * perNftReward) + change;
        uint256 rewardToGive = nftReward > remainingDayCap
            ? remainingDayCap
            : nftReward;

        require(rewardToGive > 0, "No reward");

        dayData[_token].amountClaimed += rewardToGive;

        totalClaimed[_token] += rewardToGive;

        engagementRewardId++;
        engagementRewards[engagementRewardId] = EngagementReward(
            _token,
            0,
            nftPrice,
            block.timestamp
        );

        emit EngagementRewardRegistered(
            engagementRewardId,
            _token,
            nftPrice,
            block.timestamp
        );
    }

    function claimEngagementReward(uint256 _rewardId) public nonReentrant {
        require(!isClaimedByUser[_rewardId][msg.sender], "Already claimed");
        EngagementReward memory reward = engagementRewards[_rewardId];
        uint256 availableReward = totalClaimed[reward.token] -
            engagementRewards[_rewardId].amountClaimed;
        uint256 amount = 0;
        require(availableReward > 0, "No reward to claim");
        require(reward.token != address(0), "Reward does not exist");

        uint256[] memory nftIds = IMemedWarriorNFT(
            factory.getWarriorNFT(reward.token)
        ).getWarriorMintedBeforeByUser(msg.sender, reward.timestamp);
        for (uint256 i = 0; i < nftIds.length; i++) {
            (uint256 nftReward, ) = IMemedBattle(factory.getMemedBattle())
                .getNftRewardAndIsReturnable(reward.token, nftIds[i]);
            if (availableReward >= nftReward + amount) {
                amount += nftReward;
            }
        }
        require(amount > 0, "No reward to claim");

        isClaimedByUser[_rewardId][msg.sender] = true;
        engagementRewards[_rewardId].amountClaimed += amount;
        require(
            IERC20(reward.token).transfer(msg.sender, amount),
            "Transfer failed"
        );
        emit EngagementRewardClaimed(msg.sender, _rewardId, amount);
    }

    /**
     * @dev Get battle reward pool (5% of engagement rewards per cycle)
     */
    function getBattleRewardPool(
        address _token
    ) external view returns (uint256) {
        uint256 balance = MAX_REWARD - totalClaimed[_token];
        return (balance * CYCLE_REWARD_PERCENTAGE) / 100;
    }

    function getUserEngagementReward()
        public
        view
        returns (EngagementRewardClaim[] memory)
    {
        EngagementRewardClaim[]
            memory engagementRewardsClaims = new EngagementRewardClaim[](
                engagementRewardId
            );
        uint256 index = 0;
        for (uint256 i = 1; i <= engagementRewardId; i++) {
            if (isClaimedByUser[i][msg.sender]) {
                continue;
            }
            uint256 amount = 0;
            EngagementReward memory reward = engagementRewards[i];
            uint256 availableReward = totalClaimed[reward.token] -
                engagementRewards[i].amountClaimed;

            if (reward.token == address(0)) {
                continue;
            }
            uint256[] memory nftIds = IMemedWarriorNFT(
                factory.getWarriorNFT(reward.token)
            ).getWarriorMintedBeforeByUser(msg.sender, reward.timestamp);

            for (uint256 j = 0; j < nftIds.length; j++) {
                (uint256 nftReward, ) = IMemedBattle(factory.getMemedBattle())
                    .getNftRewardAndIsReturnable(reward.token, nftIds[j]);
                if (availableReward >= nftReward + amount) {
                    amount += nftReward;
                }
            }
            if (amount > 0) {
                engagementRewardsClaims[index] = EngagementRewardClaim(
                    msg.sender,
                    i,
                    amount,
                    reward.token
                );
                index++;
            }
        }

        return engagementRewardsClaims;
    }

    /**
     * @dev Swap loser tokens to winner tokens for battle rewards
     * Routes through WETH: loser -> WETH -> winner
     * @param _loser Loser token address (token to swap from)
     * @param _winner Winner token address (token to swap to)
     * @param _loserAmount Amount of loser tokens to swap
     */
    function transferBattleRewards(
        address _loser,
        address _winner,
        uint256 _loserAmount
    ) external nonReentrant returns (uint256) {
        require(
            msg.sender == IMemedBattle(factory.getMemedBattle()).getResolver(),
            "Only resolver can transfer battle rewards"
        );
        require(
            IERC20(_loser).balanceOf(address(this)) >= _loserAmount,
            "Insufficient loser token balance"
        );

        // Transfer loser tokens to factory for swap
        require(
            IERC20(_loser).transfer(address(factory), _loserAmount),
            "Transfer to factory failed"
        );

        // Swap loser tokens to winner tokens (factory will route through WETH)
        address[] memory path = new address[](2);
        path[0] = _loser;
        path[1] = _winner;
        uint256 amountOut = factory.swap(
            _loserAmount,
            path,
            factory.getMemedBattle()
        );

        require(amountOut > 0, "Swap failed");
        totalClaimed[_loser] += _loserAmount;
        return amountOut;
    }

    function setFactory(address _factory) external onlyOwner {
        require(address(factory) == address(0), "Already set");
        factory = IMemedFactory(_factory);
    }

    function isRewardable(address _token) external view returns (bool) {
        uint256 totalNFTs = IMemedWarriorNFT(factory.getWarriorNFT(_token))
            .currentTokenId();
        if (totalNFTs == 0) return false;

        uint256 nftPrice = IMemedWarriorNFT(factory.getWarriorNFT(_token))
            .getCurrentPrice();
        uint256 perNftReward = (nftPrice *
            ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE) / 100;
        if (perNftReward == 0) return false;

        uint256 todaysClaimed = dayData[_token].amountClaimed;
        if (block.timestamp > dayData[_token].timestamp + 1 days) {
            todaysClaimed = 0;
        }

        uint256 remainingDaily = MAX_REWARD_PER_DAY - todaysClaimed;
        if (remainingDaily < perNftReward) return false;

        uint256 remainingGlobal = MAX_REWARD - totalClaimed[_token];
        if (remainingGlobal < perNftReward) return false;

        return true;
    }

    function unlockCreatorIncentives(address _token) external {
        require(
            msg.sender == address(factory),
            "Only factory can unlock creator incentives"
        );
        if (block.timestamp > dayData[_token].creatorTimestamp + 1 days) {
            dayData[_token].creatorTimestamp = block.timestamp;
            dayData[_token].claimedByCreator = 0;
        }
        uint256 remainingToday = MAX_REWARD_PER_DAY -
            dayData[_token].claimedByCreator;
        require(
            remainingToday >= CREATOR_ALLOCATION_PER_UNLOCK,
            "Daily cap reached"
        );
        uint256 unlockAmount = CREATOR_ALLOCATION_PER_UNLOCK;
        require(
            creatorData[_token].balance >= unlockAmount,
            "Not enough balance to unlock"
        );
        creatorData[_token].unlockedBalance += unlockAmount;
        creatorData[_token].balance -= unlockAmount;
        dayData[_token].claimedByCreator += unlockAmount;
        dayData[_token].creatorTimestamp = block.timestamp;
        emit CreatorIncentivesUnlocked(unlockAmount);
    }

    function claimCreatorIncentives(address _token) external {
        require(
            msg.sender == creatorData[_token].creator,
            "Only creator can claim"
        );
        uint256 amount = creatorData[_token].unlockedBalance;
        creatorData[_token].unlockedBalance = 0;

        IERC20(_token).transfer(creatorData[_token].creator, amount);
        emit CreatorIncentivesClaimed(amount);
    }

    function isCreatorRewardable(address _token) external view returns (bool) {
        uint256 amountClaimed = dayData[_token].claimedByCreator;
        if (block.timestamp > dayData[_token].creatorTimestamp + 1 days) {
            amountClaimed = 0;
        }
        uint256 amount = MAX_REWARD_PER_DAY - amountClaimed;
        return amount >= CREATOR_ALLOCATION_PER_UNLOCK;
    }

    function claimUnclaimedTokens(address _token, address to) external {
        require(to != address(0), "Invalid address");
        require(
            creatorData[_token].creator == address(0),
            "Creator already set"
        );
        creatorData[_token].creator = to;
        creatorData[_token].balance = CREATOR_INCENTIVES_ALLOCATION;
        emit CreatorSet(to);
    }
}
