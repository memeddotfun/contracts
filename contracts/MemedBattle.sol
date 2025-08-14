// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MemedFactory.sol";


interface IMemedWarriorNFT {
    function memedToken() external view returns (address);
    function getCurrentPrice() external view returns (uint256);
}



/// @title MemedBattle Contract
contract MemedBattle is Ownable, ReentrancyGuard {
    MemedFactory public factory;
    // Battle constants from Memed.fun v2.3 specification
    uint256 public constant ENGAGEMENT_WEIGHT = 60; // 60% engagement, 40% value
    uint256 public constant VALUE_WEIGHT = 40;
    uint256 public constant BATTLE_REWARD_PERCENTAGE = 5; // 5% of engagement rewards pool per cycle
    
    struct Battle {
        uint256 battleId;
        address memeA;
        address memeB;
        uint256 memeANftsAllocated;
        uint256 memeBNftsAllocated;
        uint256 heatA;
        uint256 heatB;
        uint256 startTime;
        uint256 endTime;
        bool resolved;
        address winner;
        uint256 totalReward;
    }
    
    struct UserBattleAllocation {
        uint256 battleId;
        address user;
        address supportedMeme;
        uint256[] nftsIds;
        bool claimed;
        bool getBack;
    }

    uint256 public battleDuration = 1 days;
    uint256 public battleCount;
    mapping(uint256 => Battle) public battles;
    mapping(address => uint256[]) public battleIds;
    mapping(uint256 => mapping(address => mapping(address => UserBattleAllocation))) public battleAllocations;
    mapping(address => uint256[]) public userBattles;
    mapping(uint256 => mapping(address => uint256)) public userAllocationIndex;

    event BattleStarted(uint256 battleId, address memeA, address memeB, address creatorA, address creatorB);
    event BattleResolved(uint256 battleId, address winner, uint256 engagementScore, uint256 valueScore);
    event UserAllocated(uint256 battleId, address user, address meme, uint256[] nftsIds);
    event BattleRewardsClaimed(uint256 battleId, address user, uint256 amount);
    event TokensBurned(uint256 battleId, address token, uint256 amount);
    event TokensSwapped(address indexed from, address indexed to, uint256 amountIn, uint256 amountOut);
    event RewardsDistributed(uint256 battleId, address winner, uint256 totalReward, uint256 participantCount);
    event PlatformFeeTransferred(uint256 battleId, address token, uint256 amount);

    function startBattle(address _memeB) external nonReentrant returns (uint256) {

        MemedFactory.TokenData memory tokenA = factory.getByToken(msg.sender);
        require(tokenA.token != address(0), "MemeA is not minted");
        require(tokenA.creator == msg.sender, "You are not the creator");
        require(tokenA.token != _memeB, "Cannot battle yourself");
        
        MemedFactory.TokenData memory tokenB = factory.getByToken(_memeB);
        require(tokenB.token != address(0), "MemeB is not minted");
        
        Battle storage b = battles[battleCount];
        b.battleId = battleCount;
        b.memeA = tokenA.token;
        b.memeB = tokenB.token;
        b.heatA = factory.getHeat(tokenA.token);
        b.heatB = factory.getHeat(tokenB.token);
        b.startTime = block.timestamp;
        b.endTime = block.timestamp + battleDuration;
        b.resolved = false;
        battleIds[tokenA.token].push(battleCount);
        battleIds[tokenB.token].push(battleCount);

        emit BattleStarted(battleCount, tokenA.token, tokenB.token, msg.sender, tokenB.creator);
        return battleCount++;
    }
    
    function allocateNFTsToBattle(uint256 _battleId, address _user, address _supportedMeme, uint256[] calldata _nftsIds) public nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.memeA != address(0) && battle.memeB != address(0), "Invalid battle");
        require(block.timestamp < battle.endTime, "Battle ended");
        require(!battle.resolved, "Battle resolved");
        require(_supportedMeme == battle.memeA || _supportedMeme == battle.memeB, "Invalid meme");
        address nftWarrior = factory.getWarriorNFT(_supportedMeme);
        require(nftWarrior == msg.sender, "Unauthorized");
        UserBattleAllocation storage allocation = battleAllocations[_battleId][_user][_supportedMeme];
        if(allocation.nftsIds.length == 0) {
            allocation.battleId = _battleId;
            allocation.user = _user;
            allocation.supportedMeme = _supportedMeme;
            allocation.claimed = false;
            allocation.getBack = false;
            for (uint256 i = 0; i < _nftsIds.length; i++) {
                allocation.nftsIds.push(_nftsIds[i]);
            }
        }else{
            for (uint256 i = 0; i < _nftsIds.length; i++) {
                allocation.nftsIds.push(_nftsIds[i]);
            }
        }
        if(_supportedMeme == battle.memeA) {
            battle.memeANftsAllocated += _nftsIds.length;
        }else{
            battle.memeBNftsAllocated += _nftsIds.length;
        }
        emit UserAllocated(_battleId, msg.sender, _supportedMeme, _nftsIds);
    }

    function getBackWarrior(uint256 _battleId, address _user) external {
        Battle storage battle = battles[_battleId];
        address memeA = IMemedWarriorNFT(msg.sender).memedToken();
        require(battle.winner == memeA, "Not the winner");
        UserBattleAllocation storage allocation = battleAllocations[_battleId][_user][memeA];
        require(allocation.nftsIds.length > 0, "No allocation found");
        require(!allocation.getBack, "Already got back");
        allocation.getBack = true;
    }
    
    function resolveBattle(uint256 _battleId) external {
        Battle storage battle = battles[_battleId];
        require(battle.memeA != address(0) && battle.memeB != address(0), "Invalid battle");
        require(block.timestamp >= battle.endTime, "Battle not ended");
        require(!battle.resolved, "Already resolved");
        require(msg.sender == address(factory) || msg.sender == owner(), "Unauthorized");
        
        // Get engagement scores (heat) from factory
        uint256 heatA = factory.getHeat(battle.memeA) - battle.heatA;
        uint256 heatB = factory.getHeat(battle.memeB) - battle.heatB;
        
        // Calculate final score: 60% engagement + 40% value
        uint256 valueScoreA = IMemedWarriorNFT(factory.getWarriorNFT(battle.memeA)).getCurrentPrice() * battle.memeANftsAllocated;
        uint256 valueScoreB = IMemedWarriorNFT(factory.getWarriorNFT(battle.memeB)).getCurrentPrice() * battle.memeBNftsAllocated;
        
        uint256 finalScoreA = (heatA * ENGAGEMENT_WEIGHT + valueScoreA * VALUE_WEIGHT) / 100;
        uint256 finalScoreB = (heatB * ENGAGEMENT_WEIGHT + valueScoreB * VALUE_WEIGHT) / 100;
        
        address actualWinner = finalScoreA >= finalScoreB ? battle.memeA : battle.memeB;
        address actualLoser = actualWinner == battle.memeA ? battle.memeB : battle.memeA;
        battle.winner = actualWinner;
        battle.resolved = true;
        
        
        // Winner receives 5% of engagement rewards pool (swapped to winner's token)
        uint256 battleRewardAmount = factory.memedEngageToEarn().getBattleRewardPool(actualWinner);
        if (battleRewardAmount > 0) {
            uint256 reward = factory.memedEngageToEarn().transferBattleRewards(actualLoser, actualWinner, battleRewardAmount);
            battle.totalReward = reward;
        }
        
        // Update heat for winner
        MemedFactory.HeatUpdate[] memory heatUpdate = new MemedFactory.HeatUpdate[](1);
        heatUpdate[0] = MemedFactory.HeatUpdate({
            id: factory.tokenIdByAddress(actualWinner),
            heat: 20000 // Heat boost for winning
        });
        factory.updateHeat(heatUpdate);
        
        emit BattleResolved(_battleId, actualWinner, finalScoreA + finalScoreB, valueScoreA + valueScoreB);
    }

    function claimRewards(uint256 _battleId) external {
        Battle storage battle = battles[_battleId];
        require(battle.resolved, "Battle not resolved");
        uint256 reward = battle.totalReward * battleAllocations[_battleId][msg.sender][battle.winner].nftsIds.length / (battle.winner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated);
        require(reward > 0, "No reward to claim");
        factory.memedEngageToEarn().claimBattleRewards(battle.memeA, msg.sender, reward);
        battleAllocations[_battleId][msg.sender][battle.winner].claimed = true;
        emit BattleRewardsClaimed(_battleId, msg.sender, reward);
    }

    function setFactory(address payable _factory) external onlyOwner {
        require(address(factory) == address(0), "Factory already set");
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
    
    function getBattle(uint256 _battleId) external view returns (Battle memory) {
        return battles[_battleId];
    }

    function getBattleAllocations(uint256 _battleId, address _user, address _meme) external view returns (UserBattleAllocation memory) {
        return battleAllocations[_battleId][_user][_meme];
    }

    function getUserClaimableRewards(address _user, address _token) public view returns (uint256) {
        uint256 userReward;
        uint256[] memory battleIdsArray = battleIds[_token];
        for (uint256 i = 0; i < battleIdsArray.length; i++) {
            Battle storage battle = battles[battleIdsArray[i]];
            if (battle.resolved && battle.winner == _token && !battleAllocations[battle.battleId][_user][_token].claimed) {
                userReward += battle.totalReward * battleAllocations[battle.battleId][_user][_token].nftsIds.length / (battle.winner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated);
            }
        }
        return userReward;
    }
    
    function getUserClaimableReward(uint256 _battleId, address _user) external view returns (uint256) {
        Battle storage battle = battles[_battleId];
        require(battle.resolved, "Battle not resolved");
        require(battle.winner == battle.memeA || battle.winner == battle.memeB, "Not the winner");
        require(!battleAllocations[_battleId][_user][battle.winner].claimed, "Already claimed");
        return battle.totalReward * battleAllocations[_battleId][_user][battle.winner].nftsIds.length / (battle.winner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated);
    }
}