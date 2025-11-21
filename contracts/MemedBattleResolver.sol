// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IMemedWarriorNFT.sol";
import "../interfaces/IMemedEngageToEarn.sol";
import "../interfaces/IMemedFactory.sol";
import "../interfaces/IMemedBattle.sol";
import "../structs/FactoryStructs.sol";

/// @title Memed Battle Resolver
/// @notice Resolves battles and calculates winner based on engagement and value
contract MemedBattleResolver is Ownable {
    uint256 public constant ENGAGEMENT_WEIGHT = 60;
    uint256 public constant VALUE_WEIGHT = 40;
    uint256 public constant BATTLE_REWARD_PERCENTAGE = 5;

    IMemedBattle public immutable battleContract;
    uint256[] public battleIdsToResolve;

    constructor(address _battle) Ownable(msg.sender) {
        battleContract = IMemedBattle(_battle);
    }

    /// @notice Add a battle ID to the resolution queue
    /// @param _battleId The battle ID to add
    function addBattleIdsToResolve(uint256 _battleId) external {
        require(
            msg.sender == address(battleContract),
            "Only battle can add battle ids to resolve"
        );
        battleIdsToResolve.push(_battleId);
    }

    /// @notice Resolve a battle by calculating scores and distributing rewards
    /// @param _battleId The battle ID to resolve
    function resolveBattle(uint256 _battleId) external {
        Battle memory battle = battleContract.getBattle(_battleId);
        require(
            battle.memeA != address(0) && battle.memeB != address(0),
            "Invalid battle"
        );
        require(block.timestamp >= battle.endTime, "Battle not ended");
        require(battle.status == BattleStatus.STARTED, "Battle not started");
        require(msg.sender == owner(), "Unauthorized");

        IMemedFactory factory = IMemedFactory(battleContract.getFactory());

        require(
            factory.getWarriorNFT(battle.memeA) != address(0) &&
                factory.getWarriorNFT(battle.memeB) != address(0),
            "Warrior NFTs not deployed"
        );

        uint256 finalScoreA = _calculateScore(
            factory,
            battle.memeA,
            battle.heatA,
            battle.memeANftsAllocated
        );
        uint256 finalScoreB = _calculateScore(
            factory,
            battle.memeB,
            battle.heatB,
            battle.memeBNftsAllocated
        );

        if (finalScoreA == finalScoreB) {
            battleContract.resolveBattle(_battleId, address(0), 0);
            _battleIdResolved(_battleId);
            return;
        }

        address actualWinner = finalScoreA > finalScoreB
            ? battle.memeA
            : battle.memeB;
        address actualLoser = actualWinner == battle.memeA
            ? battle.memeB
            : battle.memeA;

        uint256 totalReward = _processBattleRewards(
            factory,
            actualLoser,
            actualWinner
        );

        HeatUpdate[] memory heatUpdates = new HeatUpdate[](1);
        heatUpdates[0] = HeatUpdate(actualWinner, 20000);
        factory.updateHeat(heatUpdates);
        factory.battleUpdate(actualWinner, actualLoser);

        battleContract.resolveBattle(_battleId, actualWinner, totalReward);
        _battleIdResolved(_battleId);
    }

    /// @dev Calculate battle score based on heat and NFT value
    /// @param factory The factory contract
    /// @param token The token address
    /// @param initialHeat The initial heat score at battle start
    /// @param nftsAllocated The number of NFTs allocated
    /// @return The calculated score
    function _calculateScore(
        IMemedFactory factory,
        address token,
        uint256 initialHeat,
        uint256 nftsAllocated
    ) internal view returns (uint256) {
        uint256 currentHeat = factory.getHeat(token);
        require(currentHeat >= initialHeat, "Invalid heat calculation");
        
        uint256 heatScore = currentHeat - initialHeat;
        uint256 currentPrice = IMemedWarriorNFT(factory.getWarriorNFT(token))
            .getCurrentPrice();
        uint256 valueScore = currentPrice * nftsAllocated;
        
        uint256 totalWeight = ENGAGEMENT_WEIGHT + VALUE_WEIGHT;
        if (totalWeight == 0) {
            return 0;
        }
        
        return
            (heatScore * ENGAGEMENT_WEIGHT + valueScore * VALUE_WEIGHT) / totalWeight;
    }

    /// @dev Process battle rewards by swapping loser tokens to winner tokens
    /// @param factory The factory contract
    /// @param loser The losing token address
    /// @param winner The winning token address
    /// @return The amount of winner tokens received
    function _processBattleRewards(
        IMemedFactory factory,
        address loser,
        address winner
    ) internal returns (uint256) {
        IMemedEngageToEarn engageToEarn = IMemedEngageToEarn(
            factory.getMemedEngageToEarn()
        );
        uint256 loserTokenAmount = engageToEarn.getBattleRewardPool(loser);

        if (loserTokenAmount > 0) {
            return
                engageToEarn.transferBattleRewards(
                    loser,
                    winner,
                    loserTokenAmount
                );
        }
        return 0;
    }

    /// @dev Remove a battle ID from the resolution queue
    /// @param _battleId The battle ID to remove
    function _battleIdResolved(uint256 _battleId) internal {
        for (uint256 i = 0; i < battleIdsToResolve.length; i++) {
            if (battleIdsToResolve[i] == _battleId) {
                battleIdsToResolve[i] = battleIdsToResolve[
                    battleIdsToResolve.length - 1
                ];
                battleIdsToResolve.pop();
                break;
            }
        }
    }

    /// @notice Get all battle IDs that are ready to be resolved
    /// @return Array of battle IDs ready for resolution
    function getBattleIdsToResolve() external view returns (uint256[] memory) {
        uint256 count = 0;

        for (uint256 i = 0; i < battleIdsToResolve.length; i++) {
            Battle memory battle = battleContract.getBattle(
                battleIdsToResolve[i]
            );
            if (
                battle.status == BattleStatus.STARTED &&
                block.timestamp >= battle.endTime
            ) {
                count++;
            }
        }

        uint256[] memory _battleIdsToResolve = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < battleIdsToResolve.length; i++) {
            Battle memory battle = battleContract.getBattle(
                battleIdsToResolve[i]
            );
            if (
                battle.status == BattleStatus.STARTED &&
                block.timestamp >= battle.endTime
            ) {
                _battleIdsToResolve[index++] = battleIdsToResolve[i];
            }
        }

        return _battleIdsToResolve;
    }
}
