// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

enum BattleStatus {
    NOT_STARTED,
    CHALLENGED,
    STARTED,
    RESOLVED
}

struct TokenBattleAllocation {
    uint256 winCount;
    uint256 loseCount;
}

struct Battle {
    uint128 battleId;
    address memeA;
    address memeB;
    uint128 memeANftsAllocated;
    uint128 memeBNftsAllocated;
    uint256 heatA;
    uint256 heatB;
    uint256 startTime;
    uint256 endTime;
    BattleStatus status;
    address winner;
    uint256 totalReward;
}

struct UserBattleAllocation {
    uint128 battleId;
    address user;
    address supportedMeme;
    uint256[] nftsIds;
    bool claimed;
    bool getBack;
}

struct UserNftBattleAllocation {
    address supportedMeme;
    uint128 battleId;
}

struct BattleCooldown {
    bool onBattle;
    uint256 cooldownEndTime;
}
