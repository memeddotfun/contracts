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
    //uint256 public constant BATTLE_COOLDOWN = 14 days; // 14 days cooldown between battles
    uint256 public constant BATTLE_COOLDOWN = 20 minutes; // 20 minutes cooldown between battles for testing

    mapping(address => BattleCooldown) public battleCooldowns;
    //uint256 public constant BATTLE_DURATION = 7 days; // 7 days battle duration
    uint256 public constant BATTLE_DURATION = 20 minutes; // 20 minutes battle duration for testing
    uint256 public battleCount;
    mapping(uint256 => Battle) public battles;
    mapping(address => uint256[]) public battleIds;
    mapping(uint256 => mapping(address => mapping(address => UserBattleAllocation)))
        public battleAllocations;
    mapping(address => uint256[]) public userBattles;
    mapping(uint256 => mapping(address => uint256)) public userAllocationIndex;
    mapping(uint256 => UserNftBattleAllocation[]) public nftBattleAllocations;
    mapping(address => TokenBattleAllocation) public tokenBattleAllocations;
    mapping(address => uint256[]) public tokenAllocations;

    event BattleChallenged(uint256 battleId, address memeA, address memeB);
    event BattleStarted(uint256 battleId, address memeA, address memeB);
    event BattleResolved(
        uint256 battleId,
        address winner,
        address loser,
        uint256 totalReward
    );
    event BattleDraw(
        uint256 battleId,
        address memeA,
        address memeB
    );
    event UserAllocated(
        uint256 battleId,
        address user,
        address meme,
        uint256[] nftsIds
    );
    event BattleRewardsClaimed(uint256 battleId, address user, uint256 amount);
    event TokensBurned(uint256 battleId, address token, uint256 amount);
    event TokensSwapped(
        address indexed from,
        address indexed to,
        uint256 amountIn,
        uint256 amountOut
    );
    event RewardsDistributed(
        uint256 battleId,
        address winner,
        uint256 totalReward,
        uint256 participantCount
    );
    event PlatformFeeTransferred(
        uint256 battleId,
        address token,
        uint256 amount
    );

    constructor() Ownable(msg.sender) {}

    function challengeBattle(
        address _memeA,
        address _memeB
    ) external nonReentrant {
        TokenData memory tokenA = factory.getByToken(_memeA);
        require(tokenA.token != address(0), "MemeA is not minted");
        require(tokenA.warriorNFT != address(0), "MemeA NFT not deployed");
        require(tokenA.token != _memeB, "Cannot battle yourself");
        require(
            tokenA.creator == msg.sender ||
                (msg.sender != owner() && tokenA.isClaimedByCreator),
            "Unauthorized"
        );
        require(
            !battleCooldowns[tokenA.token].onBattle ||
                block.timestamp > battleCooldowns[tokenA.token].cooldownEndTime,
            "MemeA is on battle or cooldown"
        );
        TokenData memory tokenB = factory.getByToken(_memeB);
        require(tokenB.token != address(0), "MemeB is not minted");
        require(tokenB.warriorNFT != address(0), "MemeB NFT not deployed");
        require(
            !battleCooldowns[tokenB.token].onBattle ||
                block.timestamp > battleCooldowns[tokenB.token].cooldownEndTime,
            "MemeB is on battle or cooldown"
        );
        Battle storage b = battles[battleCount];
        b.battleId = battleCount;
        b.memeA = tokenA.token;
        b.memeB = tokenB.token;
        b.heatA = factory.getHeat(tokenA.token);
        b.heatB = factory.getHeat(tokenB.token);
        battleIds[tokenA.token].push(battleCount);
        battleIds[tokenB.token].push(battleCount);
        if (!tokenB.isClaimedByCreator) {
            _startBattle(b.battleId);
        } else {
            b.status = BattleStatus.CHALLENGED;
            emit BattleChallenged(battleCount, tokenA.token, tokenB.token);
        }

        battleCount++;
    }

    function acceptBattle(uint256 _battleId) external nonReentrant {
        Battle storage battle = battles[_battleId];
        require(
            battle.status == BattleStatus.CHALLENGED,
            "Battle not challenged"
        );
        TokenData memory tokenB = factory.getByToken(battle.memeB);
        require(tokenB.token != address(0), "MemeB is not minted");
        require(tokenB.creator == msg.sender, "Unauthorized");
        _startBattle(_battleId);
    }

    function _startBattle(uint256 _battleId) internal {
        Battle storage battle = battles[_battleId];
        battle.status = BattleStatus.STARTED;
        battle.startTime = block.timestamp;
        battle.endTime = block.timestamp + BATTLE_DURATION;
        battleCooldowns[battle.memeA].onBattle = true;
        battleCooldowns[battle.memeB].onBattle = true;
        battleCooldowns[battle.memeA].cooldownEndTime =
            block.timestamp +
            BATTLE_COOLDOWN;
        battleCooldowns[battle.memeB].cooldownEndTime =
            block.timestamp +
            BATTLE_COOLDOWN;
        battleResolver.addBattleIdsToResolve(_battleId);
        emit BattleStarted(_battleId, battle.memeA, battle.memeB);
    }

    function resolveBattle(
        uint256 _battleId,
        address _actualWinner,
        uint256 _totalReward
    ) external {
        require(msg.sender == address(battleResolver), "Unauthorized");
        Battle storage battle = battles[_battleId];
        require(battle.status == BattleStatus.STARTED, "Battle not started");
        
        if (_actualWinner == address(0)) {
            battle.status = BattleStatus.DRAW;
            battle.winner = address(0);
            battle.totalReward = 0;
            
            battleCooldowns[battle.memeA].onBattle = false;
            battleCooldowns[battle.memeB].onBattle = false;
            
            emit BattleDraw(_battleId, battle.memeA, battle.memeB);
        } else {
            address actualLoser = _actualWinner == battle.memeA
                ? battle.memeB
                : battle.memeA;
            battle.winner = _actualWinner;
            battle.status = BattleStatus.RESOLVED;
            tokenBattleAllocations[_actualWinner].winCount += _actualWinner ==
                battle.memeA
                ? battle.memeANftsAllocated
                : battle.memeBNftsAllocated;
            tokenBattleAllocations[actualLoser].loseCount += actualLoser ==
                battle.memeA
                ? battle.memeANftsAllocated
                : battle.memeBNftsAllocated;
            battleCooldowns[_actualWinner].onBattle = false;
            battleCooldowns[actualLoser].onBattle = false;
            battle.totalReward = _totalReward;
            emit BattleResolved(
                _battleId,
                _actualWinner,
                actualLoser,
                _totalReward
            );
        }
    }

    function allocateNFTsToBattle(
        uint256 _battleId,
        address _user,
        address _supportedMeme,
        uint256[] calldata _nftsIds
    ) public nonReentrant {
        Battle storage battle = battles[_battleId];
        require(
            battle.memeA != address(0) && battle.memeB != address(0),
            "Invalid battle"
        );
        require(block.timestamp < battle.endTime, "Battle ended");
        require(battle.status == BattleStatus.STARTED, "Battle not started");
        require(
            _supportedMeme == battle.memeA || _supportedMeme == battle.memeB,
            "Invalid meme"
        );
        require(msg.sender == _user, "Only user can allocate");

        // Call NFT contract to mark warriors as allocated
        address nftWarrior = factory.getWarriorNFT(_supportedMeme);
        IMemedWarriorNFT(nftWarrior).allocateNFTsToBattle(_user, _nftsIds);

        UserBattleAllocation storage allocation = battleAllocations[_battleId][
            _user
        ][_supportedMeme];
        if (allocation.nftsIds.length == 0) {
            allocation.battleId = _battleId;
            allocation.user = _user;
            allocation.supportedMeme = _supportedMeme;
            allocation.claimed = false;
            allocation.getBack = false;
            for (uint256 i = 0; i < _nftsIds.length; i++) {
                allocation.nftsIds.push(_nftsIds[i]);
                nftBattleAllocations[_nftsIds[i]].push(
                    UserNftBattleAllocation(_supportedMeme, _battleId)
                );
            }
        } else {
            for (uint256 i = 0; i < _nftsIds.length; i++) {
                allocation.nftsIds.push(_nftsIds[i]);
                nftBattleAllocations[_nftsIds[i]].push(
                    UserNftBattleAllocation(_supportedMeme, _battleId)
                );
            }
        }
        if (_supportedMeme == battle.memeA) {
            battle.memeANftsAllocated += _nftsIds.length;
        } else {
            battle.memeBNftsAllocated += _nftsIds.length;
        }
        for (uint256 i = 0; i < _nftsIds.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < tokenAllocations[_user].length; j++) {
                if (tokenAllocations[_user][j] == _nftsIds[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                tokenAllocations[_user].push(_nftsIds[i]);
            }
        }
        emit UserAllocated(_battleId, msg.sender, _supportedMeme, _nftsIds);
    }

    function getUserTokenBattleAllocations(
        uint256 _tokenId,
        uint256 _until
    ) external view returns (TokenBattleAllocation memory) {
        TokenBattleAllocation memory allocation;
        for (uint256 i = 0; i < nftBattleAllocations[_tokenId].length; i++) {
            Battle storage battle = battles[
                nftBattleAllocations[_tokenId][i].battleId
            ];
            if (
                battle.status == BattleStatus.RESOLVED &&
                battle.endTime <= _until
            ) {
                battle.winner == nftBattleAllocations[_tokenId][i].supportedMeme
                    ? allocation.winCount++
                    : allocation.loseCount++;
            }
        }
        return allocation;
    }

    function claimRewards(uint256 _battleId) external {
        Battle storage battle = battles[_battleId];
        require(battle.status == BattleStatus.RESOLVED, "Battle not resolved");
        require(
            !battleAllocations[_battleId][msg.sender][battle.winner].claimed,
            "Already claimed"
        );

        uint256 userNfts = battleAllocations[_battleId][msg.sender][
            battle.winner
        ].nftsIds.length;
        require(userNfts > 0, "No NFTs allocated");

        uint256 totalWinnerNfts = battle.winner == battle.memeA
            ? battle.memeANftsAllocated
            : battle.memeBNftsAllocated;
        require(totalWinnerNfts > 0, "No winner NFTs allocated");

        uint256 reward = (battle.totalReward * userNfts) / totalWinnerNfts;
        require(reward > 0, "No reward to claim");

        IERC20(battle.winner).transfer(msg.sender, reward);
        battleAllocations[_battleId][msg.sender][battle.winner].claimed = true;
        emit BattleRewardsClaimed(_battleId, msg.sender, reward);
    }

    /**
     * @dev Get all claimable battle rewards for a user
     * @param _user User address
     * @return battleIdsArray Array of battle IDs with claimable rewards
     * @return rewardsArray Array of reward amounts corresponding to each battle
     * @return totalReward Total claimable reward across all battles
     */
    function getUserClaimableBattles(
        address _user
    )
        external
        view
        returns (
            uint256[] memory battleIdsArray,
            uint256[] memory rewardsArray,
            uint256 totalReward
        )
    {
        // Count claimable battles
        uint256 count = 0;
        for (uint256 i = 0; i < battleCount; i++) {
            Battle storage battle = battles[i];
            if (
                battle.status == BattleStatus.RESOLVED &&
                !battleAllocations[i][_user][battle.winner].claimed &&
                battleAllocations[i][_user][battle.winner].nftsIds.length > 0
            ) {
                count++;
            }
        }

        // Build result arrays
        battleIdsArray = new uint256[](count);
        rewardsArray = new uint256[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < battleCount; i++) {
            Battle storage battle = battles[i];
            if (
                battle.status == BattleStatus.RESOLVED &&
                !battleAllocations[i][_user][battle.winner].claimed &&
                battleAllocations[i][_user][battle.winner].nftsIds.length > 0
            ) {
                uint256 totalNftsAllocated = battle.winner == battle.memeA
                    ? battle.memeANftsAllocated
                    : battle.memeBNftsAllocated;
                uint256 reward = totalNftsAllocated > 0
                    ? (battle.totalReward *
                        battleAllocations[i][_user][battle.winner]
                            .nftsIds
                            .length) / totalNftsAllocated
                    : 0;

                battleIdsArray[index] = i;
                rewardsArray[index] = reward;
                totalReward += reward;
                index++;
            }
        }
    }

    function setFactoryAndResolver(
        address _factory,
        address _resolver
    ) external onlyOwner {
        require(
            address(factory) == address(0) &&
                address(battleResolver) == address(0),
            "Factory and resolver already set"
        );
        factory = IMemedFactory(_factory);
        battleResolver = IMemedBattleResolver(_resolver);
    }

    function getResolver() external view returns (address) {
        return address(battleResolver);
    }

    function getFactory() external view returns (address) {
        return address(factory);
    }

    function getBattles() external view returns (Battle[] memory) {
        Battle[] memory battlesArray = new Battle[](battleCount);
        for (uint256 i = 0; i < battleCount; i++) {
            battlesArray[i] = battles[i];
        }
        return battlesArray;
    }

    function getUserBattles(
        address _token
    ) external view returns (Battle[] memory) {
        Battle[] memory battlesArray = new Battle[](battleCount);
        uint256 count = 0;
        for (uint256 i = 0; i < battleCount; i++) {
            if (battles[i].memeA == _token || battles[i].memeB == _token) {
                battlesArray[count] = battles[i];
                count++;
            }
        }
        return battlesArray;
    }

    function getBattle(
        uint256 _battleId
    ) external view returns (Battle memory) {
        return battles[_battleId];
    }

    function getBattleAllocations(
        uint256 _battleId,
        address _user,
        address _meme
    ) external view returns (UserBattleAllocation memory) {
        return battleAllocations[_battleId][_user][_meme];
    }

    function getUserClaimableRewards(
        address _user,
        address _token
    ) public view returns (uint256) {
        uint256 userReward;
        uint256[] memory battleIdsArray = battleIds[_token];
        for (uint256 i = 0; i < battleIdsArray.length; i++) {
            Battle storage battle = battles[battleIdsArray[i]];
            if (
                battle.status == BattleStatus.RESOLVED &&
                battle.winner == _token &&
                !battleAllocations[battle.battleId][_user][_token].claimed
            ) {
                userReward +=
                    (battle.totalReward *
                        battleAllocations[battle.battleId][_user][_token]
                            .nftsIds
                            .length) /
                    (
                        battle.winner == battle.memeA
                            ? battle.memeANftsAllocated
                            : battle.memeBNftsAllocated
                    );
            }
        }
        return userReward;
    }

    function getUserClaimableReward(
        uint256 _battleId,
        address _user
    ) external view returns (uint256) {
        Battle storage battle = battles[_battleId];
        require(battle.status == BattleStatus.RESOLVED, "Battle not resolved");
        require(
            battle.winner == battle.memeA || battle.winner == battle.memeB,
            "Not the winner"
        );
        require(
            !battleAllocations[_battleId][_user][battle.winner].claimed,
            "Already claimed"
        );
        return
            (battle.totalReward *
                battleAllocations[_battleId][_user][battle.winner]
                    .nftsIds
                    .length) /
            (
                battle.winner == battle.memeA
                    ? battle.memeANftsAllocated
                    : battle.memeBNftsAllocated
            );
    }

    function getNftRewardAndIsReturnable(
        address _token,
        uint256 _nftId
    ) external view returns (uint256, bool) {
        uint256 nftReward = ((
            IMemedWarriorNFT(factory.getWarriorNFT(_token)).getCurrentPrice()
        ) *
            IMemedEngageToEarn(factory.getMemedEngageToEarn())
                .ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE()) / 100;
        uint256 engagementRewardChange = IMemedEngageToEarn(
            factory.getMemedEngageToEarn()
        ).ENGAGEMENT_REWARDS_CHANGE();
        UserNftBattleAllocation[] memory nftAllocations = nftBattleAllocations[
            _nftId
        ];
        bool isReturnable = true;

        for (uint256 i = 0; i < nftAllocations.length; i++) {
            Battle storage battle = battles[nftAllocations[i].battleId];

            // NFT still in active battle
            if (
                battle.status == BattleStatus.STARTED ||
                battle.status == BattleStatus.CHALLENGED
            ) {
                isReturnable = false;
            }

            // Only count resolved battles
            if (battle.status == BattleStatus.RESOLVED) {
                if (nftAllocations[i].supportedMeme == battle.winner) {
                    nftReward += engagementRewardChange;
                } else {
                    // Prevent underflow
                    if (nftReward >= engagementRewardChange) {
                        nftReward -= engagementRewardChange;
                    } else {
                        isReturnable = false;
                    }
                }
            }
        }
        return (nftReward, isReturnable != false);
    }

    function getUserTokenAllocations(
        address _user
    ) external view returns (uint256[] memory) {
        return tokenAllocations[_user];
    }
}
