// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MemedFactory.sol";
import "./MemedStaking.sol";

/// @title MemedBattle Contract
contract MemedBattle is Ownable, ReentrancyGuard {
    MemedFactory public factory;
    MemedStaking public stakingContract;
    
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
        uint256 totalReward;
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
    mapping(address => uint256[]) public battleIds;
    mapping(uint256 => UserBattleAllocation[]) public battleAllocations;
    mapping(address => uint256[]) public userBattles;
    mapping(uint256 => mapping(address => uint256)) public userAllocationIndex;

    event BattleStarted(uint256 battleId, address memeA, address memeB, address creatorA, address creatorB);
    event BattleResolved(uint256 battleId, address winner, uint256 engagementScore, uint256 valueScore);
    event UserAllocated(uint256 battleId, address user, address meme, uint256 amount);
    event BattleRewardsClaimed(uint256 battleId, address user, uint256 amount);
    event TokensBurned(uint256 battleId, address token, uint256 amount);
    event TokensSwapped(address indexed from, address indexed to, uint256 amountIn, uint256 amountOut);
    event RewardsDistributed(uint256 battleId, address winner, uint256 totalReward, uint256 participantCount);
    event PlatformFeeTransferred(uint256 battleId, address token, uint256 amount);

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
        allocateTokensToBattle(battleCount, memeA, CREATOR_STAKE_REQUIREMENT);
        allocateTokensToBattle(battleCount, memeB, CREATOR_STAKE_REQUIREMENT);
        Battle storage b = battles[battleCount];
        b.battleId = battleCount;
        b.memeA = memeA;
        b.memeB = memeB;
        b.creatorA = msg.sender;
        b.creatorB = creatorB;
        b.startTime = block.timestamp;
        b.endTime = block.timestamp + battleDuration;
        b.resolved = false;
        battleIds[memeA].push(battleCount);
        battleIds[memeB].push(battleCount);

        emit BattleStarted(battleCount, memeA, memeB, msg.sender, creatorB);
        return battleCount++;
    }
    
    function allocateTokensToBattle(uint256 _battleId, address _supportedMeme, uint256 _amount) public nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.memeA != address(0) && battle.memeB != address(0), "Invalid battle");
        require(block.timestamp < battle.endTime, "Battle ended");
        require(!battle.resolved, "Battle resolved");
        require(_supportedMeme == battle.memeA || _supportedMeme == battle.memeB, "Invalid meme");
        require(_amount > 0, "Amount must be positive");
        
        // Get user's token address first
        address userToken = _getUserToken(msg.sender);
        require(userToken != address(0), "User has no meme token");
        
        // Check user's available staked balance for allocation
        uint256 availableForAllocation = stakingContract.getAvailableToken(userToken, msg.sender);
        require(availableForAllocation >= _amount, "Insufficient staked tokens available");
        
        if (userAllocationIndex[_battleId][msg.sender] == 0) {
        // Record user allocation with final amount in supported meme tokens
        UserBattleAllocation memory allocation = UserBattleAllocation({
            battleId: _battleId,
            user: msg.sender,
            supportedMeme: _supportedMeme,
            amount: _amount,
            claimed: false
        });
            battleAllocations[_battleId].push(allocation);
            userAllocationIndex[_battleId][msg.sender] = battleAllocations[_battleId].length - 1;
            userBattles[msg.sender].push(_battleId);
        } else {
            battleAllocations[_battleId][userAllocationIndex[_battleId][msg.sender]].amount += _amount;
        }
        
        // Update battle totals with final swapped amounts
        if (_supportedMeme == battle.memeA) {
            battle.totalValueA += _amount;
        } else {
            battle.totalValueB += _amount;
        }
        
        emit UserAllocated(_battleId, msg.sender, _supportedMeme, _amount);
    }
    
    function _getUserToken(address _user) internal view returns (address) {
        // Get user's meme token from factory
        address[2] memory addresses = factory.getByAddress(address(0), _user);
        return addresses[0]; // Returns address(0) if user has no meme token
    }

    function _burnTokens(address _token, uint256 _amount) internal {
        // Simple burn by sending to zero address
        // In production, this could be improved with actual burn mechanism
        IERC20(_token).transfer(address(0), _amount);
    }

    // Manual battle resolution (calculates winner internally)
    function resolveBattle(uint256 _battleId) external {
        Battle storage battle = battles[_battleId];
        require(battle.memeA != address(0) && battle.memeB != address(0), "Invalid battle");
        require(block.timestamp >= battle.endTime, "Battle not ended");
        require(!battle.resolved, "Already resolved");
        require(msg.sender == address(factory) || msg.sender == owner(), "Unauthorized");
        
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
        address loser = actualWinner == battle.memeA ? battle.memeB : battle.memeA;
        battle.winner = actualWinner;
        battle.resolved = true;
        
        // Update heat for winner
        MemedFactory.HeatUpdate[] memory heatUpdate = new MemedFactory.HeatUpdate[](1);
        heatUpdate[0] = MemedFactory.HeatUpdate({
            token: actualWinner,
            heat: 20000,
            minusHeat: false
        });
        factory.updateHeat(heatUpdate);

        uint256 loserPool = loser == battle.memeA ? battle.totalValueB : battle.totalValueA;
        stakingContract.unallocateFromBattle(loser, loserPool);
        address[] memory path = new address[](2);
        path[0] = loser;
        path[1] = actualWinner;
        uint256[] memory amounts = factory.swap(loser, loserPool, path);
        uint256 poolAmount = amounts[1];
            
            // Burn tokens
            uint256 burnAmount = poolAmount * BURN_PERCENTAGE / 100;
            _burnTokens(actualWinner, burnAmount);
            emit TokensBurned(_battleId, actualWinner, burnAmount);
            
            // Calculate platform fee safely
            uint256 platformFee = (poolAmount * BATTLE_PLATFORM_FEE_PERCENTAGE) / 100;

            // Calculate reward for distribution, ensuring no underflow
            uint256 totalReward = poolAmount;
            if (burnAmount + platformFee > poolAmount) {
                totalReward = 0;
            } else {
                totalReward = poolAmount - burnAmount - platformFee;
            }
            battle.totalReward = totalReward;
            IERC20(actualWinner).transfer(address(stakingContract), totalReward);
            
            // Transfer platform fee to owner
            if (platformFee > 0) {
                IERC20(actualWinner).transfer(owner(), platformFee);
                emit PlatformFeeTransferred(_battleId, actualWinner, platformFee);
            }
        emit BattleResolved(_battleId, actualWinner, finalScoreA + finalScoreB, valueScoreA + valueScoreB);
    }
    
    function setFactoryAndStakingContract(address payable _factory, address _stakingContract) external onlyOwner {
        require(address(factory) == address(0), "Factory already set");
        require(address(stakingContract) == address(0), "Staking contract already set");
        factory = MemedFactory(_factory);
        stakingContract = MemedStaking(_stakingContract);
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

    function getUserAllocatedToBattle(address _user, address _token) external view returns (uint256) {
        uint256 allocated = 0;
        uint256[] memory battleIdsArray = battleIds[_token];
        for (uint256 i = 0; i < battleIdsArray.length; i++) {
            Battle storage battle = battles[battleIdsArray[i]];
            UserBattleAllocation memory allocation = battleAllocations[battle.battleId][userAllocationIndex[battle.battleId][_user]];
            if ((!battle.resolved && allocation.supportedMeme == _token) || (battle.resolved && battle.winner != _token)) {
                allocated += allocation.amount;
            }
        }
        return allocated;
    }
    
    function getUserClaimableRewards(address _user, address _token) public view returns (uint256) {
        uint256 userReward;
        uint256[] memory battleIdsArray = battleIds[_token];
        for (uint256 i = 0; i < battleIdsArray.length; i++) {
            Battle storage battle = battles[battleIdsArray[i]];
            if (battle.resolved && battle.winner == _token && !battleAllocations[battle.battleId][userAllocationIndex[battle.battleId][_user]].claimed) {
                userReward += battle.totalReward * battleAllocations[battle.battleId][userAllocationIndex[battle.battleId][_user]].amount / (battle.winner == battle.memeA ? battle.totalValueA : battle.totalValueB);
            }
        }
        return userReward;
    }
    
    function claimRewards(address _user, address _token) external nonReentrant {
        require(msg.sender == address(stakingContract), "Not authorized");
        uint256 userReward = getUserClaimableRewards(_user, _token);
        uint256[] memory battleIdsArray = battleIds[_token];
        for (uint256 i = 0; i < battleIdsArray.length; i++) {
            Battle storage battle = battles[battleIdsArray[i]];
            UserBattleAllocation memory allocation = battleAllocations[battle.battleId][userAllocationIndex[battle.battleId][_user]];
            if (battle.resolved && battle.winner == _token && !allocation.claimed) {
                allocation.claimed = true;
                emit BattleRewardsClaimed(battle.battleId, _user, userReward);
            }
        }
    }
}