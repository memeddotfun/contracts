// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MemedFactory.sol";

/// @title MemedBattle Contract
contract MemedBattle is Ownable, ReentrancyGuard {
    MemedFactory public factory;
    
    // Battle constants from tokenomics
    uint256 public constant CREATOR_STAKE_REQUIREMENT = 10_000_000 * 1e18; // 10M tokens
    uint256 public constant BURN_PERCENTAGE = 15; // 15%
    uint256 public constant BATTLE_PLATFORM_FEE_PERCENTAGE = 5; // 5%
    uint256 public constant ENGAGEMENT_WEIGHT = 60; // 60% engagement, 40% value
    uint256 public constant VALUE_WEIGHT = 40;
    
    struct Battle {
        uint256 battleId;
        address memeA;
        address memeB;
        address creatorA;
        address creatorB;
        uint256 startTime;
        uint256 endTime;
        bool resolved;
        address winner;
        uint256 totalValueA;
        uint256 totalValueB;
        uint256 creatorStakeA;
        uint256 creatorStakeB;
    }
    
    struct UserBattleAllocation {
        uint256 battleId;
        address user;
        address supportedMeme;
        uint256 amount;
        bool claimed;
    }

    uint256 public battleDuration = 1 days;
    uint256 public battleCount;
    mapping(uint256 => Battle) public battles;
    mapping(uint256 => UserBattleAllocation[]) public battleAllocations;
    mapping(address => uint256[]) public userBattles;
    mapping(uint256 => mapping(address => uint256)) public userAllocationIndex;

    event BattleStarted(uint256 battleId, address memeA, address memeB, address creatorA, address creatorB);
    event BattleResolved(uint256 battleId, address winner, uint256 engagementScore, uint256 valueScore);
    event UserAllocated(uint256 battleId, address user, address meme, uint256 amount);
    event BattleRewardsClaimed(uint256 battleId, address user, uint256 amount);
    event TokensBurned(uint256 battleId, address token, uint256 amount);

    function startBattle(address _memeB) external nonReentrant returns (uint256) {
        address[2] memory addressesA = factory.getByAddress(address(0), msg.sender);
        address memeA = addressesA[0];
        address creatorA = addressesA[1];
        require(memeA != address(0), "MemeA is not minted");
        require(creatorA == msg.sender, "You are not the creator");
        
        address[2] memory addressesB = factory.getByAddress(_memeB, address(0));
        address memeB = addressesB[0];
        address creatorB = addressesB[1];
        require(memeB != address(0), "MemeB is not minted");
        require(memeB != memeA, "Cannot battle yourself");
        
        // Require 10M token stake from both creators
        require(IERC20(memeA).balanceOf(msg.sender) >= CREATOR_STAKE_REQUIREMENT, "Insufficient tokens for stake");
        require(IERC20(memeB).balanceOf(creatorB) >= CREATOR_STAKE_REQUIREMENT, "Opponent insufficient tokens");
        
        // Transfer creator stakes
        IERC20(memeA).transferFrom(msg.sender, address(this), CREATOR_STAKE_REQUIREMENT);
        IERC20(memeB).transferFrom(creatorB, address(this), CREATOR_STAKE_REQUIREMENT);
        
        Battle storage b = battles[battleCount];
        b.battleId = battleCount;
        b.memeA = memeA;
        b.memeB = memeB;
        b.creatorA = msg.sender;
        b.creatorB = creatorB;
        b.startTime = block.timestamp;
        b.endTime = block.timestamp + battleDuration;
        b.resolved = false;
        b.creatorStakeA = CREATOR_STAKE_REQUIREMENT;
        b.creatorStakeB = CREATOR_STAKE_REQUIREMENT;

        emit BattleStarted(battleCount, memeA, memeB, msg.sender, creatorB);
        return battleCount++;
    }
    
    function allocateTokensToBattle(uint256 _battleId, address _supportedMeme, uint256 _amount) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.memeA != address(0) && battle.memeB != address(0), "Invalid battle");
        require(block.timestamp < battle.endTime, "Battle ended");
        require(!battle.resolved, "Battle resolved");
        require(_supportedMeme == battle.memeA || _supportedMeme == battle.memeB, "Invalid meme");
        require(_amount > 0, "Amount must be positive");
        
        // Transfer tokens from user
        IERC20(_supportedMeme).transferFrom(msg.sender, address(this), _amount);
        
        // Apply burn and platform fee
        uint256 burnAmount = (_amount * BURN_PERCENTAGE) / 100;
        uint256 platformFee = (_amount * BATTLE_PLATFORM_FEE_PERCENTAGE) / 100;
        uint256 battleAmount = _amount - burnAmount - platformFee;
        
        // Burn tokens
        _burnTokens(_supportedMeme, burnAmount);
        
        // Send platform fee to owner
        IERC20(_supportedMeme).transfer(owner(), platformFee);
        
        // Record user allocation
        UserBattleAllocation memory allocation = UserBattleAllocation({
            battleId: _battleId,
            user: msg.sender,
            supportedMeme: _supportedMeme,
            amount: battleAmount,
            claimed: false
        });
        
        battleAllocations[_battleId].push(allocation);
        userAllocationIndex[_battleId][msg.sender] = battleAllocations[_battleId].length - 1;
        userBattles[msg.sender].push(_battleId);
        
        // Update battle totals
        if (_supportedMeme == battle.memeA) {
            battle.totalValueA += battleAmount;
        } else {
            battle.totalValueB += battleAmount;
        }
        
        emit UserAllocated(_battleId, msg.sender, _supportedMeme, battleAmount);
        emit TokensBurned(_battleId, _supportedMeme, burnAmount);
    }
    
    function _burnTokens(address _token, uint256 _amount) internal {
        // Simple burn by sending to zero address
        // In production, this could be improved with actual burn mechanism
        IERC20(_token).transfer(address(0), _amount);
    }

    function resolveBattle(uint256 _battleId, address _winner) external {
        Battle storage battle = battles[_battleId];
        require(battle.memeA != address(0) && battle.memeB != address(0), "Invalid battle");
        require(block.timestamp >= battle.endTime, "Battle not ended");
        require(!battle.resolved, "Already resolved");
        require(msg.sender == address(factory), "Unauthorized");
        
        // Get engagement scores (heat) from factory
        MemedFactory.TokenDataView[] memory tokenDataA = factory.getTokens(battle.memeA);
        MemedFactory.TokenDataView[] memory tokenDataB = factory.getTokens(battle.memeB);
        
        uint256 heatA = tokenDataA[0].heat;
        uint256 heatB = tokenDataB[0].heat;
        
        // Calculate final score: 60% engagement + 40% value
        uint256 engagementScoreA = heatA;
        uint256 engagementScoreB = heatB;
        uint256 valueScoreA = battle.totalValueA;
        uint256 valueScoreB = battle.totalValueB;
        
        uint256 finalScoreA = (engagementScoreA * ENGAGEMENT_WEIGHT + valueScoreA * VALUE_WEIGHT) / 100;
        uint256 finalScoreB = (engagementScoreB * ENGAGEMENT_WEIGHT + valueScoreB * VALUE_WEIGHT) / 100;
        
        address actualWinner = finalScoreA >= finalScoreB ? battle.memeA : battle.memeB;
        battle.winner = actualWinner;
        battle.resolved = true;
        
        // Return creator stakes to winners, burn loser stakes
        if (actualWinner == battle.memeA) {
            IERC20(battle.memeA).transfer(battle.creatorA, battle.creatorStakeA);
            _burnTokens(battle.memeB, battle.creatorStakeB);
        } else {
            IERC20(battle.memeB).transfer(battle.creatorB, battle.creatorStakeB);
            _burnTokens(battle.memeA, battle.creatorStakeA);
        }
        
        // Update heat for winner
        MemedFactory.HeatUpdate[] memory heatUpdate = new MemedFactory.HeatUpdate[](1);
        heatUpdate[0] = MemedFactory.HeatUpdate({
            token: actualWinner,
            heat: 20000,
            minusHeat: false
        });
        factory.updateHeat(heatUpdate);

        emit BattleResolved(_battleId, actualWinner, finalScoreA + finalScoreB, valueScoreA + valueScoreB);
    }
    
    function claimBattleRewards(uint256 _battleId) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.resolved, "Battle not resolved");
        
        uint256 userIndex = userAllocationIndex[_battleId][msg.sender];
        require(userIndex < battleAllocations[_battleId].length, "No allocation found");
        
        UserBattleAllocation storage allocation = battleAllocations[_battleId][userIndex];
        require(allocation.user == msg.sender, "Not your allocation");
        require(!allocation.claimed, "Already claimed");
        
        allocation.claimed = true;
        
        if (allocation.supportedMeme == battle.winner) {
            // Winner: Get back tokens plus proportional share of loser tokens
            address loserMeme = battle.winner == battle.memeA ? battle.memeB : battle.memeA;
            uint256 loserPool = battle.winner == battle.memeA ? battle.totalValueB : battle.totalValueA;
            uint256 winnerPool = battle.winner == battle.memeA ? battle.totalValueA : battle.totalValueB;
            
            uint256 baseReward = allocation.amount;
            uint256 bonusReward = 0;
            
            if (winnerPool > 0) {
                bonusReward = (allocation.amount * loserPool) / winnerPool;
            }
            
            // Convert loser tokens to winner tokens (simplified 1:1 for now)
            if (bonusReward > 0) {
                IERC20(loserMeme).transfer(msg.sender, bonusReward);
            }
            IERC20(allocation.supportedMeme).transfer(msg.sender, baseReward);
            
            emit BattleRewardsClaimed(_battleId, msg.sender, baseReward + bonusReward);
        } else {
            // Loser: Tokens are automatically swapped to winner token
            address winnerMeme = battle.winner;
            IERC20(winnerMeme).transfer(msg.sender, allocation.amount);
            
            emit BattleRewardsClaimed(_battleId, msg.sender, allocation.amount);
        }
    }
    
    function setFactory(address payable _factory) external onlyOwner {
        require(address(factory) == address(0), "Already set");
        factory = MemedFactory(_factory);
    }
    
    function getBattles() external view returns (Battle[] memory) {
        Battle[] memory battlesArray = new Battle[](battleCount);
        for (uint256 i = 0; i < battleCount; i++) {
            battlesArray[i] = battles[i];
        }
        return battlesArray;
    }

    function getUserBattles(address _token) external view returns (Battle[] memory) {
        Battle[] memory battlesArray = new Battle[](battleCount);
        uint256 count = 0;
        for (uint256 i = 0; i < battleCount; i++) {
            if(battles[i].memeA == _token || battles[i].memeB == _token) {
                battlesArray[count] = battles[i];
                count++;
            }
        }
        return battlesArray;
    }
    
    function getBattleAllocations(uint256 _battleId) external view returns (UserBattleAllocation[] memory) {
        return battleAllocations[_battleId];
    }
    
    function getUserBattleHistory(address _user) external view returns (uint256[] memory) {
        return userBattles[_user];
    }
    
    function getUserAllocation(uint256 _battleId, address _user) external view returns (UserBattleAllocation memory) {
        uint256 index = userAllocationIndex[_battleId][_user];
        require(index < battleAllocations[_battleId].length, "No allocation found");
        return battleAllocations[_battleId][index];
    }
}