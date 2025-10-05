// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct TokenBattleAllocation {
    uint256 winCount;
    uint256 loseCount;
}

interface IMemedBattle {
    function tokenBattleAllocations(address _token) external view returns (TokenBattleAllocation memory);
    function getUserTokenBattleAllocations(uint256 _tokenId, uint256 _until) external view returns (TokenBattleAllocation memory);
    function tokenAllocations(address _user) external view returns (uint256[] memory);
}
