// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

struct TokenData {
    address token;
    address warriorNFT;
    address creator;
    bool isClaimedByCreator;
}

struct TokenRewardData {
    uint256 lastRewardAt;
    uint256 creatorIncentivesUnlocksAt;
    uint256 creatorIncentivesUnlockedAt;
    uint256 lastEngagementBoost;
    uint256 heat;
    uint256 lastHeatUpdate;
    uint256 createdAt;
}

struct HeatUpdate {
    address token;
    uint256 heat;
}
