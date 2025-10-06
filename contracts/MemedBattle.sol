// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IMemedWarriorNFT.sol";
import "../interfaces/IMemedEngageToEarn.sol";
import "../interfaces/IMemedFactory.sol";
import "../interfaces/IMemedBattle.sol";
import "../structs/FactoryStructs.sol";

/// @title MemedBattle Contract
contract MemedBattle is Ownable, ReentrancyGuard {
    error TokenNotMinted();
    error SelfBattle();
    error Unauthorized();
    error OnCooldown();
    error InvalidBattle();
    error BattleEnded();
    error BattleNotStarted();
    error InvalidMeme();
    error NotWinner();
    error NoAllocation();
    error AlreadyRetrieved();
    error BattleNotEnded();
    error NotChallenged();
    error NotResolved();
    error AlreadyClaimed();
    error NoReward();
    error FactorySet();

    IMemedFactory public factory;
    uint8 public constant ENGAGEMENT_WEIGHT = 60;
    uint8 public constant VALUE_WEIGHT = 40;
    uint8 public constant BATTLE_REWARD_PERCENTAGE = 5;
    uint32 public constant BATTLE_COOLDOWN = 14 days;
    
    mapping(address => BattleCooldown) public battleCooldowns;
    uint32 public battleDuration = 1 days;
    uint128 public battleCount;
    mapping(uint128 => Battle) public battles;
    mapping(address => uint128[]) public battleIds;
    mapping(uint128 => mapping(address => mapping(address => UserBattleAllocation))) public battleAllocations;
    mapping(uint256 => UserNftBattleAllocation[]) public nftBattleAllocations;
    mapping(address => TokenBattleAllocation) public tokenBattleAllocations;
    mapping(address => uint256[]) public tokenAllocations;

    event BattleChallenged(uint256 battleId, address memeA, address memeB);
    event BattleStarted(uint256 battleId, address memeA, address memeB);
    event BattleResolved(uint256 battleId, address winner, uint256 engagementScore, uint256 valueScore);
    event UserAllocated(uint256 battleId, address user, address meme, uint256[] nftsIds);
    event BattleRewardsClaimed(uint256 battleId, address user, uint256 amount);
    event RewardsDistributed(uint256 battleId, address winner, uint256 totalReward, uint256 participantCount);

    constructor() Ownable(msg.sender) {}

    function challengeBattle(address _memeA, address _memeB) external nonReentrant {
        TokenData memory tokenA = factory.getByToken(_memeA);
        if(tokenA.token == address(0)) revert TokenNotMinted();
        if(tokenA.token == _memeB) revert SelfBattle();
        if(tokenA.creator != msg.sender && (msg.sender == owner() || !tokenA.isClaimedByCreator)) revert Unauthorized();
        BattleCooldown memory cooldownA = battleCooldowns[tokenA.token];
        if(cooldownA.onBattle && block.timestamp <= cooldownA.cooldownEndTime) revert OnCooldown();
        
        TokenData memory tokenB = factory.getByToken(_memeB);
        if(tokenB.token == address(0)) revert TokenNotMinted();
        BattleCooldown memory cooldownB = battleCooldowns[tokenB.token];
        if(cooldownB.onBattle && block.timestamp <= cooldownB.cooldownEndTime) revert OnCooldown();
        
        uint128 id = battleCount;
        Battle storage b = battles[id];
        b.battleId = id;
        b.memeA = tokenA.token;
        b.memeB = tokenB.token;
        b.heatA = factory.getHeat(tokenA.token);
        b.heatB = factory.getHeat(tokenB.token);
        battleIds[tokenA.token].push(id);
        battleIds[tokenB.token].push(id);
        
        if(!tokenB.isClaimedByCreator) {
            _startBattle(id);
        } else {
            b.status = BattleStatus.CHALLENGED;
            emit BattleChallenged(id, tokenA.token, tokenB.token);
        }
        unchecked { battleCount++; }
    }

    function acceptBattle(uint128 _battleId) external nonReentrant {
        Battle storage battle = battles[_battleId];
        if(battle.status != BattleStatus.CHALLENGED) revert NotChallenged();
        TokenData memory tokenB = factory.getByToken(battle.memeB);
        if(tokenB.token == address(0)) revert TokenNotMinted();
        if(tokenB.creator != msg.sender) revert Unauthorized();
        _startBattle(_battleId);
    }

    function _startBattle(uint128 _battleId) internal {
        Battle storage battle = battles[_battleId];
        battle.status = BattleStatus.STARTED;
        uint256 time = block.timestamp;
        battle.startTime = time;
        unchecked {
            battle.endTime = time + battleDuration;
            uint256 cooldown = time + BATTLE_COOLDOWN;
            battleCooldowns[battle.memeA] = BattleCooldown(true, cooldown);
            battleCooldowns[battle.memeB] = BattleCooldown(true, cooldown);
        }
        emit BattleStarted(_battleId, battle.memeA, battle.memeB);
    }
    
    function allocateNFTsToBattle(uint128 _battleId, address _user, address _supportedMeme, uint256[] calldata _nftsIds) public nonReentrant {
        Battle storage battle = battles[_battleId];
        if(battle.memeA == address(0)) revert InvalidBattle();
        if(block.timestamp >= battle.endTime) revert BattleEnded();
        if(battle.status != BattleStatus.STARTED) revert BattleNotStarted();
        if(_supportedMeme != battle.memeA && _supportedMeme != battle.memeB) revert InvalidMeme();
        if(factory.getWarriorNFT(_supportedMeme) != msg.sender) revert Unauthorized();
        
        UserBattleAllocation storage allocation = battleAllocations[_battleId][_user][_supportedMeme];
        if(allocation.nftsIds.length == 0) {
            allocation.battleId = _battleId;
            allocation.user = _user;
            allocation.supportedMeme = _supportedMeme;
        }
        
        uint256 len = _nftsIds.length;
        for (uint256 i; i < len;) {
            uint256 nftId = _nftsIds[i];
            allocation.nftsIds.push(nftId);
            nftBattleAllocations[nftId].push(UserNftBattleAllocation(_supportedMeme, uint128(_battleId)));
            
            uint256[] storage userTokens = tokenAllocations[_user];
            uint256 tokLen = userTokens.length;
            bool found;
            for (uint256 j; j < tokLen;) {
                if(userTokens[j] == nftId) {
                    found = true;
                    break;
                }
                unchecked { ++j; }
            }
            if(!found) userTokens.push(nftId);
            unchecked { ++i; }
        }
        
        if(_supportedMeme == battle.memeA) {
            unchecked { battle.memeANftsAllocated += uint128(len); }
        } else {
            unchecked { battle.memeBNftsAllocated += uint128(len); }
        }
        emit UserAllocated(_battleId, _user, _supportedMeme, _nftsIds);
    }

    function getBackWarrior(uint128 _battleId, address _user) external {
        Battle storage battle = battles[_battleId];
        address meme = IMemedWarriorNFT(msg.sender).memedToken();
        if(battle.winner != meme) revert NotWinner();
        UserBattleAllocation storage allocation = battleAllocations[_battleId][_user][meme];
        if(allocation.nftsIds.length == 0) revert NoAllocation();
        if(allocation.getBack) revert AlreadyRetrieved();
        allocation.getBack = true;
    }
    
    function resolveBattle(uint128 _battleId) external {
        Battle storage battle = battles[_battleId];
        if(battle.memeA == address(0)) revert InvalidBattle();
        if(block.timestamp < battle.endTime) revert BattleNotEnded();
        if(battle.status != BattleStatus.STARTED) revert BattleNotStarted();
        if(msg.sender != address(factory) && msg.sender != owner()) revert Unauthorized();
        
        uint256 heatA;
        uint256 heatB;
        unchecked {
            heatA = factory.getHeat(battle.memeA) - battle.heatA;
            heatB = factory.getHeat(battle.memeB) - battle.heatB;
        }
        
        uint256 valueScoreA = IMemedWarriorNFT(factory.getWarriorNFT(battle.memeA)).getCurrentPrice() * battle.memeANftsAllocated;
        uint256 valueScoreB = IMemedWarriorNFT(factory.getWarriorNFT(battle.memeB)).getCurrentPrice() * battle.memeBNftsAllocated;
        
        uint256 finalScoreA;
        uint256 finalScoreB;
        unchecked {
            finalScoreA = (heatA * ENGAGEMENT_WEIGHT + valueScoreA * VALUE_WEIGHT) / 100;
            finalScoreB = (heatB * ENGAGEMENT_WEIGHT + valueScoreB * VALUE_WEIGHT) / 100;
        }
        
        bool isAWinner = finalScoreA >= finalScoreB;
        address winner = isAWinner ? battle.memeA : battle.memeB;
        address loser = isAWinner ? battle.memeB : battle.memeA;
        battle.winner = winner;
        battle.status = BattleStatus.RESOLVED;
        
        unchecked {
            tokenBattleAllocations[winner].winCount += isAWinner ? battle.memeANftsAllocated : battle.memeBNftsAllocated;
            tokenBattleAllocations[loser].loseCount += isAWinner ? battle.memeBNftsAllocated : battle.memeANftsAllocated;
        }
        
        battleCooldowns[winner].onBattle = false;
        battleCooldowns[loser].onBattle = false;
        
        uint256 battleRewardAmount = IMemedEngageToEarn(factory.getMemedEngageToEarn()).getBattleRewardPool(winner);
        if (battleRewardAmount > 0) {
            battle.totalReward = IMemedEngageToEarn(factory.getMemedEngageToEarn()).transferBattleRewards(loser, winner, battleRewardAmount);
        }
        
        factory.updateHeat(winner, 20000);
        factory.battleUpdate(winner, loser);
        unchecked {
            emit BattleResolved(_battleId, winner, finalScoreA + finalScoreB, valueScoreA + valueScoreB);
        }
    }

    function getUserTokenBattleAllocations(uint256 _tokenId, uint256 _until) external view returns (TokenBattleAllocation memory allocation) {
        UserNftBattleAllocation[] memory allocs = nftBattleAllocations[_tokenId];
        uint256 len = allocs.length;
        for (uint256 i; i < len;) {
            UserNftBattleAllocation memory alloc = allocs[i];
            Battle storage battle = battles[alloc.battleId];
            if(battle.status == BattleStatus.RESOLVED && battle.endTime <= _until) {
                unchecked {
                    battle.winner == alloc.supportedMeme ? ++allocation.winCount : ++allocation.loseCount;
                    ++i;
                }
            } else {
                unchecked { ++i; }
            }
        }
    }

    function claimRewards(uint128 _battleId) external {
        Battle storage battle = battles[_battleId];
        if(battle.status != BattleStatus.RESOLVED) revert NotResolved();
        UserBattleAllocation storage allocation = battleAllocations[_battleId][msg.sender][battle.winner];
        if(allocation.claimed) revert AlreadyClaimed();
        uint256 reward = battle.totalReward * allocation.nftsIds.length / (battle.winner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated);
        if(reward == 0) revert NoReward();
        allocation.claimed = true;
        IMemedEngageToEarn(factory.getMemedEngageToEarn()).claimBattleRewards(battle.memeA, msg.sender, reward);
        emit BattleRewardsClaimed(_battleId, msg.sender, reward);
    }

    function setFactory(address _factory) external onlyOwner {
        if(address(factory) != address(0)) revert FactorySet();
        factory = IMemedFactory(_factory);
    }
    

    function getBattles() external view returns (Battle[] memory battlesArray) {
        uint128 count = battleCount;
        battlesArray = new Battle[](count);
        for (uint128 i; i < count;) {
            battlesArray[i] = battles[i];
            unchecked { ++i; }
        }
    }

    function getUserBattles(address _token) external view returns (Battle[] memory) {
        uint128[] memory ids = battleIds[_token];
        uint256 len = ids.length;
        Battle[] memory battlesArray = new Battle[](len);
        for (uint256 i; i < len;) {
            battlesArray[i] = battles[ids[i]];
            unchecked { ++i; }
        }
        return battlesArray;
    }
    
    function getBattle(uint128 _battleId) external view returns (Battle memory) {
        return battles[_battleId];
    }

    function getBattleAllocations(uint128 _battleId, address _user, address _meme) external view returns (UserBattleAllocation memory) {
        return battleAllocations[_battleId][_user][_meme];
    }

    function getUserClaimableRewards(address _user, address _token) public view returns (uint256 userReward) {
        uint128[] memory ids = battleIds[_token];
        uint256 len = ids.length;
        for (uint256 i; i < len;) {
            uint128 id = ids[i];
            Battle storage battle = battles[id];
            if (battle.status == BattleStatus.RESOLVED && battle.winner == _token) {
                UserBattleAllocation storage allocation = battleAllocations[id][_user][_token];
                if(!allocation.claimed) {
                    unchecked {
                        userReward += battle.totalReward * allocation.nftsIds.length / (battle.winner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated);
                    }
                }
            }
            unchecked { ++i; }
        }
    }
    
    function getUserClaimableReward(uint128 _battleId, address _user) external view returns (uint256) {
        Battle storage battle = battles[_battleId];
        if(battle.status != BattleStatus.RESOLVED) revert NotResolved();
        UserBattleAllocation storage allocation = battleAllocations[_battleId][_user][battle.winner];
        if(allocation.claimed) revert AlreadyClaimed();
        return battle.totalReward * allocation.nftsIds.length / (battle.winner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated);
    }
}