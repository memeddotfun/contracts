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

interface IMemedBattle {
    function tokenBattleAllocations(address _token) external view returns (TokenBattleAllocation memory);
    function getUserTokenBattleAllocations(uint256 _tokenId, uint256 _until) external view returns (TokenBattleAllocation memory);
    function tokenAllocations(address _user) external view returns (uint256[] memory);
    function getBattle(uint256 _battleId) external view returns (Battle memory);
    function getBattleAllocations(uint256 _battleId, address _user, address _meme) external view returns (UserBattleAllocation memory);
    function getBackWarrior(uint256 _battleId, address _user) external;
    function allocateNFTsToBattle(uint256 _battleId, address _user, address _supportedMeme, uint256[] calldata _nftsIds) external;
}
