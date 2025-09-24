// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


interface IMemedWarriorNFT {
    function memedToken() external view returns (address);
    function getCurrentPrice() external view returns (uint256);
}

interface IMemedEngageToEarn {
    function getUserEngagementReward(address _user, address _token) external view returns (uint256);
    function isRewardable(address _token) external view returns (bool);
    function registerEngagementReward(address _token) external;
    function getBattleRewardPool(address _token) external view returns (uint256);
    function transferBattleRewards(address _loser, address _winner, uint256 _amount) external returns (uint256);
    function claimBattleRewards(address _token, address _winner, uint256 _amount) external;
}

interface IMemedFactory {
    struct TokenData {
        address token;
        address warriorNFT;
        address creator;
        bool isClaimedByCreator;
        string name;
        string ticker;
        string description;
        string image;
        string lensUsername;
        uint256 lastRewardAt;
        uint256 createdAt;
    }
    
    function getByToken(address _token) external view returns (TokenData memory);
    function updateHeat(HeatUpdate[] calldata _heatUpdates) external;
    function getHeat(address _token) external view returns (uint256);
    function getWarriorNFT(address _token) external view returns (address);
    function getTokenId(address _token) external view returns (uint256);
    function getMemedEngageToEarn() external view returns (IMemedEngageToEarn);
    function owner() external view returns (address);
    function platformFeePercentage() external view returns (uint256);
    function feeDenominator() external view returns (uint256);
    function swapExactForNativeToken(uint256 _amount, address _token, address _to) external returns (uint[] memory amounts);
    function battleUpdate(address _winner, address _loser) external;
}

struct HeatUpdate {
    uint256 id;
    uint256 heat;
}



/// @title MemedBattle Contract
contract MemedBattle is Ownable, ReentrancyGuard {
    IMemedFactory public factory;
    // Battle constants from Memed.fun v2.3 specification
    uint256 public constant ENGAGEMENT_WEIGHT = 60; // 60% engagement, 40% value
    uint256 public constant VALUE_WEIGHT = 40;
    uint256 public constant BATTLE_REWARD_PERCENTAGE = 5; // 5% of engagement rewards pool per cycle
    uint256 public constant BATTLE_COOLDOWN = 14 days;

    enum BattleStatus {
        NOT_STARTED,
        CHALLENGED,
        STARTED,
        RESOLVED
    }
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
        BattleStatus status;
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

    struct TokenBattleAllocation {
        uint256 winCount;
        uint256 loseCount;
    }
    struct UserNftBattleAllocation {
        address supportedMeme;
        uint256 battleId;
    }

    struct BattleCooldown {
        bool onBattle;
        uint256 cooldownEndTime;
    }

    mapping(address => BattleCooldown) public battleCooldowns;
    uint256 public battleDuration = 1 days;
    uint256 public battleCount;
    mapping(uint256 => Battle) public battles;
    mapping(address => uint256[]) public battleIds;
    mapping(uint256 => mapping(address => mapping(address => UserBattleAllocation))) public battleAllocations;
    mapping(address => uint256[]) public userBattles;
    mapping(uint256 => mapping(address => uint256)) public userAllocationIndex;
    mapping(uint256 => UserNftBattleAllocation[]) public nftBattleAllocations;
    mapping(address => TokenBattleAllocation) public tokenBattleAllocations;
    mapping(address => uint256[]) public tokenAllocations;

    event BattleChallenged(uint256 battleId, address memeA, address memeB);
    event BattleStarted(uint256 battleId, address memeA, address memeB);
    event BattleResolved(uint256 battleId, address winner, uint256 engagementScore, uint256 valueScore);
    event UserAllocated(uint256 battleId, address user, address meme, uint256[] nftsIds);
    event BattleRewardsClaimed(uint256 battleId, address user, uint256 amount);
    event TokensBurned(uint256 battleId, address token, uint256 amount);
    event TokensSwapped(address indexed from, address indexed to, uint256 amountIn, uint256 amountOut);
    event RewardsDistributed(uint256 battleId, address winner, uint256 totalReward, uint256 participantCount);
    event PlatformFeeTransferred(uint256 battleId, address token, uint256 amount);

    function challengeBattle(address _memeA, address _memeB) external nonReentrant {
        IMemedFactory.TokenData memory tokenA = factory.getByToken(_memeA);
        require(tokenA.token != address(0), "MemeA is not minted");
        require(tokenA.token != _memeB, "Cannot battle yourself");
        require(tokenA.creator == msg.sender || (msg.sender != owner() && tokenA.isClaimedByCreator), "Unauthorized");
        require(!battleCooldowns[tokenA.token].onBattle || block.timestamp > battleCooldowns[tokenA.token].cooldownEndTime, "MemeA is on battle or cooldown");
        IMemedFactory.TokenData memory tokenB = factory.getByToken(_memeB);
        require(tokenB.token != address(0), "MemeB is not minted");
        require(!battleCooldowns[tokenB.token].onBattle || block.timestamp > battleCooldowns[tokenB.token].cooldownEndTime, "MemeB is on battle or cooldown");
        Battle storage b = battles[battleCount];
        b.battleId = battleCount;
        b.memeA = tokenA.token;
        b.memeB = tokenB.token;
        b.heatA = factory.getHeat(tokenA.token);
        b.heatB = factory.getHeat(tokenB.token);
        battleIds[tokenA.token].push(battleCount);
        battleIds[tokenB.token].push(battleCount);
        if(!tokenB.isClaimedByCreator) {
            _startBattle(b.battleId);
    }else{
        b.status = BattleStatus.CHALLENGED;
        emit BattleChallenged(battleCount, tokenA.token, tokenB.token);
    }

        battleCount++;
    }

    function acceptBattle(uint256 _battleId) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.status == BattleStatus.CHALLENGED, "Battle not challenged");
        IMemedFactory.TokenData memory tokenB = factory.getByToken(battle.memeB);
        require(tokenB.token != address(0), "MemeB is not minted");
        require(tokenB.creator == msg.sender, "Unauthorized");
        _startBattle(_battleId);
    }

    function _startBattle(uint256 _battleId) internal {
        Battle storage battle = battles[_battleId];
        battle.status = BattleStatus.STARTED;
        battle.startTime = block.timestamp;
        battle.endTime = block.timestamp + battleDuration;
        battleCooldowns[battle.memeA].onBattle = true;
        battleCooldowns[battle.memeB].onBattle = true;
        battleCooldowns[battle.memeA].cooldownEndTime = block.timestamp + BATTLE_COOLDOWN;
        battleCooldowns[battle.memeB].cooldownEndTime = block.timestamp + BATTLE_COOLDOWN;
        emit BattleStarted(_battleId, battle.memeA, battle.memeB);
    }
    
    function allocateNFTsToBattle(uint256 _battleId, address _user, address _supportedMeme, uint256[] calldata _nftsIds) public nonReentrant {
        Battle storage battle = battles[_battleId];
        require(battle.memeA != address(0) && battle.memeB != address(0), "Invalid battle");
        require(block.timestamp < battle.endTime, "Battle ended");
        require(battle.status == BattleStatus.STARTED, "Battle not started");
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
               nftBattleAllocations[_nftsIds[i]].push(UserNftBattleAllocation(_supportedMeme, _battleId));
            }
        }else{
            for (uint256 i = 0; i < _nftsIds.length; i++) {
                allocation.nftsIds.push(_nftsIds[i]);
                nftBattleAllocations[_nftsIds[i]].push(UserNftBattleAllocation(_supportedMeme, _battleId));
            }
        }
        if(_supportedMeme == battle.memeA) {
            battle.memeANftsAllocated += _nftsIds.length;
        }else{
            battle.memeBNftsAllocated += _nftsIds.length;
        }
        for (uint256 i = 0; i < _nftsIds.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < tokenAllocations[_user].length; j++) {
                if(tokenAllocations[_user][j] == _nftsIds[i]) {
                    found = true;
                    break;
                }
            }
        if(!found) {
            tokenAllocations[_user].push(_nftsIds[i]);
        }
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
        require(battle.status == BattleStatus.STARTED, "Battle not started");
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
        battle.status = BattleStatus.RESOLVED;
        tokenBattleAllocations[actualWinner].winCount+= actualWinner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated;
        tokenBattleAllocations[actualLoser].loseCount+= actualLoser == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated;
        battleCooldowns[actualWinner].onBattle = false;
        battleCooldowns[actualLoser].onBattle = false;
        
        
        // Winner receives 5% of engagement rewards pool (swapped to winner's token)
        uint256 battleRewardAmount = factory.getMemedEngageToEarn().getBattleRewardPool(actualWinner);
        if (battleRewardAmount > 0) {
            uint256 reward = factory.getMemedEngageToEarn().transferBattleRewards(actualLoser, actualWinner, battleRewardAmount);
            battle.totalReward = reward;
        }
        
        // Update heat for winner
        HeatUpdate[] memory heatUpdate = new HeatUpdate[](1);
        heatUpdate[0].id = factory.getTokenId(actualWinner);
        heatUpdate[0].heat = 20000; // Heat boost for winning
        factory.updateHeat(heatUpdate);
        factory.battleUpdate(actualWinner, actualLoser);
        emit BattleResolved(_battleId, actualWinner, finalScoreA + finalScoreB, valueScoreA + valueScoreB);
    }

    function getUserTokenBattleAllocations(uint256 _tokenId, uint256 _until) external view returns (TokenBattleAllocation memory) {
        TokenBattleAllocation memory allocation;
        for (uint256 i = 0; i < nftBattleAllocations[_tokenId].length; i++) {
            Battle storage battle = battles[nftBattleAllocations[_tokenId][i].battleId];
            if(battle.status == BattleStatus.RESOLVED && battle.endTime <= _until) {
                battle.winner == nftBattleAllocations[_tokenId][i].supportedMeme ? allocation.winCount++ : allocation.loseCount++;
            }
        }
        return allocation;
    }

    function claimRewards(uint256 _battleId) external {
        Battle storage battle = battles[_battleId];
        require(battle.status == BattleStatus.RESOLVED, "Battle not resolved");
        uint256 reward = battle.totalReward * battleAllocations[_battleId][msg.sender][battle.winner].nftsIds.length / (battle.winner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated);
        require(reward > 0, "No reward to claim");
        factory.getMemedEngageToEarn().claimBattleRewards(battle.memeA, msg.sender, reward);
        battleAllocations[_battleId][msg.sender][battle.winner].claimed = true;
        emit BattleRewardsClaimed(_battleId, msg.sender, reward);
    }

    function setFactory(address payable _factory) external onlyOwner {
        require(address(factory) == address(0), "Factory already set");
        factory = IMemedFactory(_factory);
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
            if (battle.status == BattleStatus.RESOLVED && battle.winner == _token && !battleAllocations[battle.battleId][_user][_token].claimed) {
                userReward += battle.totalReward * battleAllocations[battle.battleId][_user][_token].nftsIds.length / (battle.winner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated);
            }
        }
        return userReward;
    }
    
    function getUserClaimableReward(uint256 _battleId, address _user) external view returns (uint256) {
        Battle storage battle = battles[_battleId];
        require(battle.status == BattleStatus.RESOLVED, "Battle not resolved");
        require(battle.winner == battle.memeA || battle.winner == battle.memeB, "Not the winner");
        require(!battleAllocations[_battleId][_user][battle.winner].claimed, "Already claimed");
        return battle.totalReward * battleAllocations[_battleId][_user][battle.winner].nftsIds.length / (battle.winner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated);
    }
}