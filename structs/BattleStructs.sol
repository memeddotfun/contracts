// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

enum BattleStatus {
    NOT_STARTED,
    CHALLENGED,
    STARTED,
    RESOLVED,
    DRAW,
    REJECTED
}

struct TokenBattleAllocation {
    uint256 winCount;
    uint256 loseCount;
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
    uint256 challengeTime;
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

struct UserNftBattleAllocation {
    address supportedMeme;
    uint256 battleId;
}

struct BattleCooldown {
    bool onBattle;
    uint256 cooldownEndTime;
}
