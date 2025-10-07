// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IMemedWarriorNFT.sol";
import "../interfaces/IMemedEngageToEarn.sol";
import "../interfaces/IMemedFactory.sol";
import "../interfaces/IMemedBattle.sol";
import "../structs/FactoryStructs.sol";

/// @title MemedBattleResolver Contract
contract MemedBattleResolver is Ownable {

    
    uint256 public constant ENGAGEMENT_WEIGHT = 60; // 60% engagement, 40% value
    uint256 public constant VALUE_WEIGHT = 40;
    uint256 public constant BATTLE_REWARD_PERCENTAGE = 5; // 5% of engagement rewards pool per cycle

    IMemedBattle public immutable battleContract;
    uint256[] public battleIdsToResolve;

    event BattleResolved(uint256 indexed battleId, address indexed winner, address indexed loser, uint256 totalReward);

    constructor(address _battle) Ownable(msg.sender) {
        battleContract = IMemedBattle(_battle);
    }

    function addBattleIdsToResolve(uint256 _battleId) external {
        require(msg.sender == address(battleContract), "Only battle can add battle ids to resolve");
        battleIdsToResolve.push(_battleId);
    }
    
    
    
    function resolveBattle(uint256 _battleId) external {
        Battle memory battle = battleContract.getBattle(_battleId);
        require(battle.memeA != address(0) && battle.memeB != address(0), "Invalid battle");
        require(block.timestamp >= battle.endTime, "Battle not ended");
        require(battle.status == BattleStatus.STARTED, "Battle not started");
        require(msg.sender == owner(), "Unauthorized");
        IMemedFactory factory = IMemedFactory(battleContract.getFactory());
        // Get engagement scores (heat) from factory
        uint256 heatA = factory.getHeat(battle.memeA) - battle.heatA;
        uint256 heatB = factory.getHeat(battle.memeB) - battle.heatB;
        
        // Calculate final score: 60% engagement + 40% value
        uint256 valueScoreA = IMemedWarriorNFT(factory.getWarriorNFT(battle.memeA)).getCurrentPrice() * battle.memeANftsAllocated;
        uint256 valueScoreB = IMemedWarriorNFT(factory.getWarriorNFT(battle.memeB)).getCurrentPrice() * battle.memeBNftsAllocated;
        
        uint256 finalScoreA = (heatA * ENGAGEMENT_WEIGHT + valueScoreA * VALUE_WEIGHT) / 100;
        uint256 finalScoreB = (heatB * ENGAGEMENT_WEIGHT + valueScoreB * VALUE_WEIGHT) / 100;
        
        address actualWinner = finalScoreA >= finalScoreB ? battle.memeA : battle.memeB;
        address actualLoser = actualWinner == battle.memeA ? battle.memeB : battle.memeA;
        
        // Winner receives 5% of engagement rewards pool (swapped to winner's token)
        uint256 battleRewardAmount = IMemedEngageToEarn(factory.getMemedEngageToEarn()).getBattleRewardPool(actualWinner);
        uint256 totalReward;
        if (battleRewardAmount > 0) {
            totalReward = IMemedEngageToEarn(factory.getMemedEngageToEarn()).transferBattleRewards(actualLoser, actualWinner, battleRewardAmount);
        }
        
        // Update heat for winner
        factory.updateHeat(actualWinner, 20000);
        factory.battleUpdate(actualWinner, actualLoser);
        battleContract.resolveBattle(_battleId, actualWinner, totalReward);
        _battleIdResolved(_battleId);
        emit BattleResolved(_battleId, actualWinner, actualLoser, totalReward);
    }

    function _battleIdResolved(uint256 _battleId) internal {
        for (uint256 i = 0; i < battleIdsToResolve.length; i++) {
            if (battleIdsToResolve[i] == _battleId) {
                battleIdsToResolve[i] = battleIdsToResolve[battleIdsToResolve.length - 1];
                battleIdsToResolve.pop();
                break;
            }
        }
    }

    function getBattleIdsToResolve() external view returns (uint256[] memory) {
        uint256 count = 0;
        
        // Count eligible battles
        for (uint256 i = 0; i < battleIdsToResolve.length; i++) {
            Battle memory battle = battleContract.getBattle(battleIdsToResolve[i]);
            if (battle.status == BattleStatus.STARTED && block.timestamp >= battle.endTime) {
                count++;
            }
        }
        
        // Build result array
        uint256[] memory _battleIdsToResolve = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < battleIdsToResolve.length; i++) {
            Battle memory battle = battleContract.getBattle(battleIdsToResolve[i]);
            if (battle.status == BattleStatus.STARTED && block.timestamp >= battle.endTime) {
                _battleIdsToResolve[index++] = battleIdsToResolve[i];
            }
        }
        
        return _battleIdsToResolve;
    }
}