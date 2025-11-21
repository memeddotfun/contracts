// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

struct EngagementReward {
    address token;
    uint256 amountClaimed;
    uint256 nftPrice;
    uint256 timestamp;
}

struct EngagementRewardClaim {
    address user;
    uint256 rewardId;
    uint256 amountToClaim;
    address token;
}

struct CreatorData {
    address creator;
    uint256 balance;
    uint256 unlockedBalance;
}

struct DayData {
    uint256 timestamp;
    uint256 amountClaimed;
    uint256 claimedByCreator;
    uint256 creatorTimestamp;
}
