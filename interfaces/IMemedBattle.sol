// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "../structs/BattleStructs.sol";

/// @title IMemedBattle
/// @notice Interface for the Memed Battle contract
interface IMemedBattle {
    function tokenBattleAllocations(
        address _token
    ) external view returns (TokenBattleAllocation memory);
    function getUserTokenBattleAllocations(
        uint256 _tokenId,
        uint256 _until
    ) external view returns (TokenBattleAllocation memory);
    function getUserTokenAllocations(
        address _user
    ) external view returns (uint256[] memory);
    function getBattle(uint256 _battleId) external view returns (Battle memory);
    function getBattleAllocations(
        uint256 _battleId,
        address _user,
        address _meme
    ) external view returns (UserBattleAllocation memory);
    function allocateNFTsToBattle(
        uint256 _battleId,
        address _user,
        address _supportedMeme,
        uint256[] calldata _nftsIds
    ) external;
    function getFactory() external view returns (address);
    function getResolver() external view returns (address);
    function resolveBattle(
        uint256 _battleId,
        address _actualWinner,
        uint256 _totalReward
    ) external;
    function getNftRewardAndIsReturnable(
        address _token,
        uint256 _nftId
    ) external view returns (uint256, bool);
    function getBattleScore(
        uint256 _battleId
    ) external view returns (
        uint256 scoreA,
        uint256 scoreB,
        uint256 heatScoreA,
        uint256 heatScoreB,
        uint256 valueScoreA,
        uint256 valueScoreB
    );
}
