// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../structs/BattleStructs.sol";

interface IMemedBattleResolver {
    function addBattleIdsToResolve(uint256 _battleId) external;
    function resolveBattle(uint256 _battleId) external;
}
