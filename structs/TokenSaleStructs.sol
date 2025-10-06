// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

enum FairLaunchStatus {
    NOT_STARTED,
    ACTIVE,
    READY_TO_COMPLETE,
    COMPLETED,
    FAILED
}

struct Commitment {
    uint256 amount;
    uint256 tokenAmount;
    bool claimed;
    bool refunded;
}

struct FairLaunchData {
    FairLaunchStatus status;
    uint256 fairLaunchStartTime;
    uint256 totalCommitted;
    uint256 totalSold;
    address uniswapPair;
    mapping(address => Commitment) commitments;
    mapping(address => uint256) balance;
    uint256 createdAt;
}
