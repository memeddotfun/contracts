// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../structs/TokenStructs.sol";

contract MemedToken is ERC20, Ownable {
    uint256 public immutable MAX_SUPPLY;
    
    // Token distribution according to Memed.fun v2.3 tokenomics
    uint256 public constant FAIR_LAUNCH_ALLOCATION = 200000000 * 1e18; // 200M (20%)
    uint256 public immutable LP_ALLOCATION;
    uint256 public constant ENGAGEMENT_REWARDS_ALLOCATION = 350000000 * 1e18; // 350M (35%)
    uint256 public constant CREATOR_INCENTIVES_ALLOCATION = 150000000 * 1e18; // 150M (15%)
    uint256 public constant CREATOR_INITIAL_ALLOCATION = 50000000 * 1e18; // 50M (5%)
    uint256 public constant CREATOR_INITIAL_ALLOCATION_PER_UNLOCK = 2000000 * 1e18; // 2M tokens
    bool public isLpAllocated;
    address public engageToEarnContract;
    address public factoryContract;
    

    CreatorData public creatorData;

    event CreatorIncentivesUnlocked(uint256 amount);
    event CreatorIncentivesClaimed(uint256 amount);
    event LpAllocated(uint256 amount);
    
    constructor(
        string memory _name,
        string memory _ticker,
        address _creator,
        address _factoryContract,
        address _engageToEarnContract,
        uint256 _lpSupply
    ) ERC20(_name, _ticker) Ownable(msg.sender) {
        creatorData.creator = _creator; 
        creatorData.balance = CREATOR_INCENTIVES_ALLOCATION * 70 / 100;
        factoryContract = _factoryContract;
        engageToEarnContract = _engageToEarnContract;
        MAX_SUPPLY = 700000000 * 1e18 + _lpSupply;
        LP_ALLOCATION = _lpSupply;
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

    function allocateLp() external onlyFactory {
        require(!isLpAllocated, "Lp already allocated");
        _mint(factoryContract, LP_ALLOCATION);
        isLpAllocated = true;
        emit LpAllocated(LP_ALLOCATION);
    }

    function claim(address to, uint256 amount) external onlyFactory {
        require(to != address(0), "Invalid address");
        require(amount > 0, "Invalid amount");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        _mint(to, amount);
    }
}
