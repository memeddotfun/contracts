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
import "../interfaces/IMemedBattleResolver.sol";



/// @title MemedBattle Contract
contract MemedBattle is Ownable, ReentrancyGuard {
    IMemedBattleResolver public battleResolver;
    IMemedFactory public factory;
    // Battle constants from Memed.fun v2.3 specification
    uint256 public constant BATTLE_COOLDOWN = 14 days;

    
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
    event BattleResolved(uint256 battleId, address winner, address loser, uint256 totalReward);
    event UserAllocated(uint256 battleId, address user, address meme, uint256[] nftsIds);
    event BattleRewardsClaimed(uint256 battleId, address user, uint256 amount);
    event TokensBurned(uint256 battleId, address token, uint256 amount);
    event TokensSwapped(address indexed from, address indexed to, uint256 amountIn, uint256 amountOut);
    event RewardsDistributed(uint256 battleId, address winner, uint256 totalReward, uint256 participantCount);
    event PlatformFeeTransferred(uint256 battleId, address token, uint256 amount);

    constructor() Ownable(msg.sender) {}

    function challengeBattle(address _memeA, address _memeB) external nonReentrant {
        TokenData memory tokenA = factory.getByToken(_memeA);
        require(tokenA.token != address(0), "MemeA is not minted");
        require(tokenA.token != _memeB, "Cannot battle yourself");
        require(tokenA.creator == msg.sender || (msg.sender != owner() && tokenA.isClaimedByCreator), "Unauthorized");
        require(!battleCooldowns[tokenA.token].onBattle || block.timestamp > battleCooldowns[tokenA.token].cooldownEndTime, "MemeA is on battle or cooldown");
        TokenData memory tokenB = factory.getByToken(_memeB);
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
        TokenData memory tokenB = factory.getByToken(battle.memeB);
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

    function resolveBattle(uint256 _battleId, address _actualWinner, uint256 _totalReward) external {
        require(msg.sender == address(battleResolver), "Unauthorized");
        Battle storage battle = battles[_battleId];
        address actualLoser = _actualWinner == battle.memeA ? battle.memeB : battle.memeA;
        battle.winner = _actualWinner;
        battle.status = BattleStatus.RESOLVED;
        tokenBattleAllocations[_actualWinner].winCount+= _actualWinner == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated;
        tokenBattleAllocations[actualLoser].loseCount+= actualLoser == battle.memeA ? battle.memeANftsAllocated : battle.memeBNftsAllocated;
        battleCooldowns[_actualWinner].onBattle = false;
        battleCooldowns[actualLoser].onBattle = false;
        battle.totalReward = _totalReward;
        emit BattleResolved(_battleId, _actualWinner, actualLoser, _totalReward);
        
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
        IMemedEngageToEarn(factory.getMemedEngageToEarn()).claimBattleRewards(battle.memeA, msg.sender, reward);
        battleAllocations[_battleId][msg.sender][battle.winner].claimed = true;
        emit BattleRewardsClaimed(_battleId, msg.sender, reward);
    }

    function setFactoryAndResolver(address _factory, address _resolver) external onlyOwner {
        require(address(factory) == address(0) && address(battleResolver) == address(0), "Factory and resolver already set");
        factory = IMemedFactory(_factory);
        battleResolver = IMemedBattleResolver(_resolver);
    }
    
    function getResolver() external view returns (address) {
        return address(battleResolver);
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