// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IMemedWarriorNFT {
    function hasActiveWarrior(address user) external view returns (bool);
    function getUserActiveNFTs(address user) external view returns (uint256[] memory);
    function getCurrentPrice(uint256 tokenId) external view returns (uint256);
}

interface IMemedFactory {
    function swap(uint256 _amount, address[] calldata _path, address _to) external returns (uint256[] memory);
}

contract MemedEngageToEarn is Ownable {
    uint256 public constant MAX_REWARD = 350_000_000 * 1e18; // 350M tokens for engagement rewards (v2.3)
    uint256 public constant CYCLE_REWARD_PERCENTAGE = 5; // 5% of engagement rewards per cycle for battles
    uint256 public constant ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE = 20; // 20% of engagement rewards per nft as per their price
    
    IMemedFactory public factory;
    uint256 public totalEngagementRewards;
    
    struct EngagementReward {
        uint256 amount;
        uint256 nftPrice;
        uint256 timestamp;
    }

    mapping(address => EngagementReward) public engagementRewards;

    /**
     * @dev Get battle reward pool (5% of engagement rewards per cycle)
     */
    function getBattleRewardPool(address _token) external view returns (uint256) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        return (balance * CYCLE_REWARD_PERCENTAGE) / 100;
    }
    
    /**
     * @dev Swap tokens to winner (called by battle contract)
     */
    function transferBattleRewards(address _token, address _winner, uint256 _amount) external returns (uint256) {
        require(msg.sender == address(factory), "Only factory can transfer battle rewards");
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "Insufficient balance");
        IERC20(_token).transfer(address(factory), _amount);
        address[] memory path = new address[](2);
        path[0] = _token;
        path[1] = _winner;
        uint256[] memory amounts = factory.swap(_amount, path, _winner);
        require(amounts[1] > 0, "Swap failed");
        return amounts[1];
    }

    function claimBattleRewards(address _token, address _winner, uint256 _amount) external {
        require(msg.sender == address(factory), "Only factory can transfer battle rewards");
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "Insufficient balance");
        IERC20(_token).transfer(_winner, _amount);
    }

    function setFactory(address _factory) external onlyOwner {
        require(address(factory) == address(0), "Already set");
        factory = IMemedFactory(_factory);
    }
    
}