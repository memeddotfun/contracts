// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../structs/TokenStructs.sol";

contract MemedToken is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = 1000000000 * 1e18; // 1B (100%)
    
    // Token distribution according to Memed.fun v2.3 tokenomics
    uint256 public constant FAIR_LAUNCH_ALLOCATION = 200000000 * 1e18; // 200M (20%)
    uint256 public constant LP_ALLOCATION = 100000000 * 1e18; // 100M (10%)
    uint256 public constant ENGAGEMENT_REWARDS_ALLOCATION = 500000000 * 1e18; // 500M (50%)
    uint256 public constant CREATOR_INCENTIVES_ALLOCATION = 200000000 * 1e18; // 200M (20%)
    uint256 public constant CREATOR_INITIAL_ALLOCATION = 60000000 * 1e18; // 60M (6%)
    uint256 public constant CREATOR_INITIAL_ALLOCATION_PER_UNLOCK = 2000000 * 1e18; // 2M tokens
    bool public isLpAllocated;
    address public engageToEarnContract;
    address public factoryContract;
    

    CreatorData public creatorData;

    event CreatorIncentivesUnlocked(uint256 amount);
    event CreatorIncentivesClaimed(uint256 amount);
    event LpAllocated(uint256 amount);
    event CreatorSet(address to);
    
    constructor(
        string memory _name,
        string memory _ticker,
        address _creator,
        address _factoryContract,
        address _engageToEarnContract,
        address _memedTokenSale
    ) ERC20(_name, _ticker) Ownable(msg.sender) {
        creatorData.creator = _creator; 
        creatorData.balance = CREATOR_INCENTIVES_ALLOCATION * 70 / 100;
        factoryContract = _factoryContract;
        engageToEarnContract = _engageToEarnContract;
        _mint(engageToEarnContract, ENGAGEMENT_REWARDS_ALLOCATION);
        _mint(_memedTokenSale, FAIR_LAUNCH_ALLOCATION);
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
    function claimUnclaimedTokens(address to) external onlyFactory {
        require(to != address(0), "Invalid address");
        require(creatorData.creator == address(0), "Creator already set");
        creatorData.creator = to;
        creatorData.balance = CREATOR_INCENTIVES_ALLOCATION * 70 / 100;
        _mint(to, CREATOR_INITIAL_ALLOCATION);
        emit CreatorSet(to);
    }
}
