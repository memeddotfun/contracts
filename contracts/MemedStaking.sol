// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MemedFactory.sol";

contract MemedStaking is Ownable, ReentrancyGuard {   
    uint256 public constant MAX_REWARD = 200_000_000 * 1e18; // 200M tokens for staking rewards
    uint256 public constant TOKENS_PER_HEAT = 100 * 10**18;
    uint256 public constant EARLY_UNSTAKING_PENALTY = 10; // 10% penalty
    uint256 public constant MINIMUM_STAKE_PERIOD = 7 days; // Minimum stake period to avoid penalty
    
    // Quarterly APR schedule (basis points: 100 = 1%)
    uint256[4] public quarterlyAPR = [15000, 10000, 7500, 5000]; // 150%, 100%, 75%, 50%
    uint256 public constant QUARTER_DURATION = 90 days; // 3 months
    uint256 public stakingStartTime;

    MemedFactory public factory;
    
    struct Stake {
        uint256 amount;
        uint256 reward;
        uint256 stakeTime;
        uint256 lastRewardClaim;
    }
    
    struct StakingPeriod {
        uint256 startTime;
        uint256 endTime;
        uint256 apr;
        bool active;
    }

    mapping(address => address[]) stakers;
    mapping(address => mapping(address => Stake)) public stakes; // meme => user => Stake
    mapping(address => uint256) public totalStakedPerMeme;
    mapping(uint256 => StakingPeriod) public stakingPeriods; // quarter => period info
    uint256 public currentQuarter;

    event Staked(address indexed user, address meme, uint256 amount, uint256 currentAPR);
    event Unstaked(address indexed user, address meme, uint256 amount, uint256 penalty);
    event RewardClaimed(address indexed user, address meme, uint256 amount);
    event Reward(address indexed meme, uint256 amount);
    event QuarterUpdated(uint256 quarter, uint256 apr);
    event EarlyUnstakePenalty(address indexed user, address meme, uint256 penaltyAmount);

    constructor() {
        stakingStartTime = block.timestamp;
        _initializeStakingPeriods();
    }
    
    function _initializeStakingPeriods() internal {
        for (uint256 i = 0; i < 4; i++) {
            stakingPeriods[i] = StakingPeriod({
                startTime: stakingStartTime + (i * QUARTER_DURATION),
                endTime: stakingStartTime + ((i + 1) * QUARTER_DURATION),
                apr: quarterlyAPR[i],
                active: i == 0 // Only first quarter is initially active
            });
        }
        currentQuarter = 0;
    }
    
    function updateCurrentQuarter() external {
        uint256 newQuarter = (block.timestamp - stakingStartTime) / QUARTER_DURATION;
        if (newQuarter > currentQuarter && newQuarter < 4) {
            stakingPeriods[currentQuarter].active = false;
            currentQuarter = newQuarter;
            stakingPeriods[currentQuarter].active = true;
            
            emit QuarterUpdated(currentQuarter, quarterlyAPR[currentQuarter]);
        }
    }
    
    function getCurrentAPR() public view returns (uint256) {
        uint256 quarter = (block.timestamp - stakingStartTime) / QUARTER_DURATION;
        if (quarter >= 4) {
            return quarterlyAPR[3]; // Use last quarter's rate after year 1
        }
        return quarterlyAPR[quarter];
    }

    function stake(address meme, uint256 amount) external nonReentrant {
        require(amount > 0, "Stake more than zero");
        require(IERC20(meme).balanceOf(msg.sender) >= amount, "Not enough tokens");
        
        // Update quarter if needed
        uint256 quarter = (block.timestamp - stakingStartTime) / QUARTER_DURATION;
        if (quarter > currentQuarter && quarter < 4) {
            stakingPeriods[currentQuarter].active = false;
            currentQuarter = quarter;
            stakingPeriods[currentQuarter].active = true;
        }
        
        IERC20(meme).transferFrom(msg.sender, address(this), amount);
        
        // Calculate and add any pending rewards before updating stake
        _updateRewards(meme, msg.sender);
        
        if(stakes[meme][msg.sender].amount == 0) {
            stakers[meme].push(msg.sender);
            stakes[meme][msg.sender].stakeTime = block.timestamp;
            stakes[meme][msg.sender].lastRewardClaim = block.timestamp;
        }
        
        stakes[meme][msg.sender].amount += amount;
        totalStakedPerMeme[meme] += amount;
        
        MemedFactory.HeatUpdate[] memory heatUpdate = new MemedFactory.HeatUpdate[](1);
        heatUpdate[0] = MemedFactory.HeatUpdate({
            token: meme,
            heat: amount / TOKENS_PER_HEAT,
            minusHeat: false
        });
        factory.updateHeat(heatUpdate);
        
        emit Staked(msg.sender, meme, amount, getCurrentAPR());
    }

    function unstake(address meme, uint256 amount) external nonReentrant {
        require(amount > 0, "Nothing to unstake");
        require(stakes[meme][msg.sender].amount >= amount, "Not enough staked");
        
        // Calculate and add any pending rewards
        _updateRewards(meme, msg.sender);
        
        uint256 penalty = 0;
        uint256 amountToReturn = amount;
        
        // Apply early unstaking penalty if staked for less than minimum period
        if (block.timestamp < stakes[meme][msg.sender].stakeTime + MINIMUM_STAKE_PERIOD) {
            penalty = (amount * EARLY_UNSTAKING_PENALTY) / 100;
            amountToReturn = amount - penalty;
            
            // Burn penalty tokens
            IERC20(meme).transfer(address(0), penalty);
            emit EarlyUnstakePenalty(msg.sender, meme, penalty);
        }
        
        stakes[meme][msg.sender].amount -= amount;
        totalStakedPerMeme[meme] -= amount;
        
        if(stakes[meme][msg.sender].amount == 0) {
            for(uint i = 0; i < stakers[meme].length; i++) {
                if(stakers[meme][i] == msg.sender) {
                    stakers[meme][i] = stakers[meme][stakers[meme].length - 1];
                    stakers[meme].pop();
                    break;
                }
            }
        }
        
        MemedFactory.HeatUpdate[] memory heatUpdate = new MemedFactory.HeatUpdate[](1);
        heatUpdate[0] = MemedFactory.HeatUpdate({
            token: meme,
            heat: amount / TOKENS_PER_HEAT,
            minusHeat: true
        });
        factory.updateHeat(heatUpdate);
        
        IERC20(meme).transfer(msg.sender, amountToReturn);
        emit Unstaked(msg.sender, meme, amountToReturn, penalty);
    }
    
    function _updateRewards(address meme, address user) internal {
        Stake storage userStake = stakes[meme][user];
        if (userStake.amount == 0) return;
        
        uint256 timeStaked = block.timestamp - userStake.lastRewardClaim;
        if (timeStaked == 0) return;
        
        // Calculate rewards based on current APR and time staked
        uint256 currentAPR = getCurrentAPR();
        uint256 rewardAmount = (userStake.amount * currentAPR * timeStaked) / (365 days * 10000);
        
        userStake.reward += rewardAmount;
        userStake.lastRewardClaim = block.timestamp;
    }
    
    function claimReward(address meme) external nonReentrant {
        _updateRewards(meme, msg.sender);
        
        uint256 amount = stakes[meme][msg.sender].reward;
        require(amount > 0, "Nothing to claim");
        require(IERC20(meme).balanceOf(address(this)) >= amount, "Not enough tokens in contract");
        
        stakes[meme][msg.sender].reward = 0;
        IERC20(meme).transfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, meme, amount);
    }
    
    function getPendingRewards(address meme, address user) external view returns (uint256) {
        Stake memory userStake = stakes[meme][user];
        if (userStake.amount == 0) return userStake.reward;
        
        uint256 timeStaked = block.timestamp - userStake.lastRewardClaim;
        uint256 currentAPR = getCurrentAPR();
        uint256 pendingReward = (userStake.amount * currentAPR * timeStaked) / (365 days * 10000);
        
        return userStake.reward + pendingReward;
    }

    function reward(address meme, address _creator) external {
        require(IERC20(meme).balanceOf(address(this)) >= (MAX_REWARD * 3) / 100, "Not enough tokens");
        require(msg.sender == address(factory), "unauthorized");
        
        uint256 totalReward = MAX_REWARD * 2 / 100;
        uint256 totalStaked = totalStakedPerMeme[meme];
        
        if (totalStaked > 0) {
            for(uint i = 0; i < stakers[meme].length; i++) {
                address user = stakers[meme][i];
                uint256 userStakedAmount = stakes[meme][user].amount;
                uint256 userAmount = userStakedAmount * totalReward / totalStaked;
                stakes[meme][user].reward += userAmount;
            }
        }
        
        IERC20(meme).transfer(_creator, MAX_REWARD * 1 / 100);
        emit Reward(meme, MAX_REWARD * 3 / 100);
    }

    function setFactory(address _factory) external onlyOwner {
        require(address(factory) == address(0), "Already set");
        factory = MemedFactory(_factory);
    }

    function isRewardable(address meme) external view returns (bool) {
        return (IERC20(meme).balanceOf(address(this)) >= (MAX_REWARD * 3) / 100) && (stakers[meme].length > 0);
    }

    function getStakers(address meme) external view returns (address[] memory) {
        return stakers[meme];
    }
    
    function getStakeInfo(address meme, address user) external view returns (
        uint256 amount,
        uint256 reward,
        uint256 stakeTime,
        uint256 pendingRewards,
        uint256 currentAPR
    ) {
        Stake memory userStake = stakes[meme][user];
        uint256 pending = this.getPendingRewards(meme, user);
        
        return (
            userStake.amount,
            userStake.reward,
            userStake.stakeTime,
            pending,
            getCurrentAPR()
        );
    }
    
    function getQuarterInfo(uint256 quarter) external view returns (StakingPeriod memory) {
        require(quarter < 4, "Invalid quarter");
        return stakingPeriods[quarter];
    }
}
