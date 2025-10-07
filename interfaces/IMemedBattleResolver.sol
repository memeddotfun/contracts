// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../structs/BattleStructs.sol";

interface IMemedBattleResolver {
    function addBattleIdsToResolve(uint128 _battleId) external;
    function resolveBattle(uint128 _battleId) external;
}
