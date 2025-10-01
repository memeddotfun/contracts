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
    uint256 public constant CREATOR_INITIAL_ALLOCATION = (MAX_SUPPLY * 5) / 100; // 50M (5%)
    uint256 public constant CREATOR_INITIAL_ALLOCATION_PER_UNLOCK = 2000000 * 1e18; // 2M tokens

    address public engageToEarnContract;
    address public factoryContract;
    
    struct CreatorData {
        address creator;
        uint256 balance;
        uint256 unlockedBalance;
    }

    CreatorData public creatorData;

    event CreatorIncentivesUnlocked(uint256 amount);
    event CreatorIncentivesClaimed(uint256 amount);
    
    constructor(
        string memory _name,
        string memory _ticker,
        address _creator,
        address _factoryContract,
        address _engageToEarnContract
    ) ERC20(_name, _ticker) Ownable(_factoryContract) {
        creatorData.creator = _creator; 
        creatorData.balance = CREATOR_INCENTIVES_ALLOCATION * 70 / 100;
        factoryContract = _factoryContract;
        engageToEarnContract = _engageToEarnContract;
        
        _mint(engageToEarnContract, ENGAGEMENT_REWARDS_ALLOCATION);
        if(_creator != address(0)) {
            _mint(_creator, CREATOR_INITIAL_ALLOCATION);
        }
    }
    
    modifier onlyFactory() {
        require(msg.sender == factoryContract, "Only factory can call this function");
        _;
    }
    
    function unlockCreatorIncentives() external onlyFactory {
        uint256 amount = CREATOR_INITIAL_ALLOCATION_PER_UNLOCK;
        require(creatorData.balance >= amount, "Not enough balance to unlock");
        creatorData.unlockedBalance += amount;
        creatorData.balance -= amount;
        emit CreatorIncentivesUnlocked(amount);
    }

    function claimCreatorIncentives() external {
        require(msg.sender == creatorData.creator, "Only creator can claim");
        uint256 amount = creatorData.unlockedBalance;
        creatorData.unlockedBalance = 0;

        _mint(creatorData.creator, amount);
        emit CreatorIncentivesClaimed(amount);
    }

    function isRewardable() external view returns (bool) {
        return creatorData.balance > CREATOR_INITIAL_ALLOCATION_PER_UNLOCK;
    }

    function claim(address to, uint256 amount) external onlyFactory {
        _mint(to, amount);
    }
    
    function mintUniswapLP(address to, uint256 amount) external onlyFactory {
        _mint(to, amount);
    }
}
