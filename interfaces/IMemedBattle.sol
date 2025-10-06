// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../structs/BattleStructs.sol";

interface IMemedBattle {
    function tokenBattleAllocations(
        address _token
    ) external view returns (TokenBattleAllocation memory);
    function getUserTokenBattleAllocations(
        uint256 _tokenId,
        uint256 _until
    ) external view returns (TokenBattleAllocation memory);
    function tokenAllocations(
        address _user
    ) external view returns (uint256[] memory);
    function getBattle(uint128 _battleId) external view returns (Battle memory);
    function getBattleAllocations(
        uint128 _battleId,
        address _user,
        address _meme
    ) external view returns (UserBattleAllocation memory);
    function getBackWarrior(uint128 _battleId, address _user) external;
    function allocateNFTsToBattle(
        uint128 _battleId,
        address _user,
        address _supportedMeme,
        uint256[] calldata _nftsIds
    ) external;
}
