// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MemedToken is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1B tokens
    
    // Token distribution according to Memed.fun v2.3 tokenomics
    uint256 public constant FAIR_LAUNCH_ALLOCATION = (MAX_SUPPLY * 20) / 100; // 200M (20%)
    uint256 public constant ENGAGEMENT_REWARDS_ALLOCATION = (MAX_SUPPLY * 35) / 100; // 350M (35%)
    uint256 public constant CREATOR_INCENTIVES_ALLOCATION = (MAX_SUPPLY * 15) / 100; // 150M (15%)
    uint256 public constant UNISWAP_LP_ALLOCATION = (MAX_SUPPLY * 30) / 100; // 300M (30%)
    
    address public engageToEarnContract;
    address public factoryContract;
    
    struct CreatorData {
        address creator;
        uint256 balance;
        uint256 lastRewardAt;
    }

    CreatorData public creatorData;
    
    constructor(
        string memory _name,
        string memory _ticker,
        address _creator,
        address _factoryContract,
        address _engageToEarnContract
    ) ERC20(_name, _ticker) Ownable() {
        creatorData.creator = _creator; 
        creatorData.balance = CREATOR_INCENTIVES_ALLOCATION * 70 / 100;
        creatorData.lastRewardAt = block.timestamp;
        factoryContract = _factoryContract;
        engageToEarnContract = _engageToEarnContract;
        
        // Initial distribution - v2.3 tokenomics (no staking rewards, increased engagement rewards)
        _mint(engageToEarnContract, ENGAGEMENT_REWARDS_ALLOCATION);
        _mint(_creator, CREATOR_INCENTIVES_ALLOCATION * 30 / 100); // 30% instant to creator
    }

    function claimCreatorIncentives() external {
        require(msg.sender == creatorData.creator, "Only creator can claim");
        require(block.timestamp >= creatorData.lastRewardAt + 30 days, "Not enough time has passed");
        
        uint256 amount = CREATOR_INCENTIVES_ALLOCATION * 35 / 100;
        require(creatorData.balance >= amount, "Not enough balance to claim"); // 35% of creator incentives
        creatorData.balance -= amount;
        creatorData.lastRewardAt = block.timestamp;

        _mint(creatorData.creator, amount);
    }

    function claim(address to, uint256 amount) external {
        require(msg.sender == factoryContract, "Only factory can mint");
        _mint(to, amount);
    }
    
    function mintUniswapLP(address to) external {
        require(msg.sender == factoryContract, "Only factory can mint");
        _mint(to, UNISWAP_LP_ALLOCATION);
    }
}
