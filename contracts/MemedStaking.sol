// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MemedFactory.sol";

interface IMemedBattle {
    function getUserAllocatedToBattle(address user, address token) external view returns (uint256);
    function getUserClaimableRewards(address user, address token) external view returns (uint256);
    function claimRewards(address user, address token) external;
}

contract MemedStaking is Ownable, ReentrancyGuard {   
    uint256 public constant MAX_REWARD = 200_000_000 * 1e18; // 200M tokens for staking rewards
    uint256 public constant TOKENS_PER_HEAT = 100 * 10**18;
    uint256 public constant EARLY_UNSTAKING_PENALTY = 10; // 10% penalty
    uint256 public constant MINIMUM_STAKE_PERIOD = 7 days; // Minimum stake period to avoid penalty
    uint256 public constant REWARD_UPDATE_INTERVAL = 1 hours; // Update rewards every hour
    
    // Default quarterly APR schedule (basis points: 100 = 1%)
    uint256[4] public defaultQuarterlyAPR = [15000, 10000, 7500, 5000]; // 150%, 100%, 75%, 50%
    uint256 public constant DEFAULT_QUARTER_DURATION = 90 days; // 3 months
    
    // Global fallback timing
    uint256 public stakingStartTime;

    MemedFactory public factory;
    IMemedBattle public memedBattle;
    
    struct Stake {
        uint256 amount;
        uint256 pendingRewards;
        uint256 stakeTime;
        uint256 lastRewardUpdate;
        uint256 accumulatedRewards;
        bool autoCompound;
    }
    
    struct TokenStakingPeriod {
        uint256 startTime;
        uint256 endTime;
        uint256 duration;
        uint256 apr;
        bool active;
    }
    
    struct TokenQuarterConfig {
        uint256[4] quarterlyAPR;
        uint256 quarterDuration;
        uint256 stakingStartTime;
        uint256 currentQuarter;
        bool hasCustomConfig;
    }
    
    struct TokenStakingInfo {
        uint256 totalStaked;
        uint256 totalRewardsDistributed;
        uint256 lastGlobalRewardUpdate;
        uint256 rewardPerTokenStored;
        uint256 globalRewardRate; // Rewards per second per token
    }

    mapping(address => address[]) stakers;
    mapping(address => mapping(address => Stake)) public stakes; // meme => user => Stake
    mapping(address => TokenStakingInfo) public tokenStakingInfo;
    
    // Token-specific quarter configurations
    mapping(address => TokenQuarterConfig) public tokenQuarterConfigs;
    mapping(address => mapping(uint256 => TokenStakingPeriod)) public tokenStakingPeriods; // token => quarter => period info
    
    // Global quarter system (fallback)
    mapping(uint256 => TokenStakingPeriod) public globalStakingPeriods; // quarter => period info
    uint256 public globalCurrentQuarter;

    // Events
    event Staked(address indexed user, address meme, uint256 amount, uint256 currentAPR, bool autoCompound);
    event Unstaked(address indexed user, address meme, uint256 amount, uint256 penalty);
    event RewardClaimed(address indexed user, address meme, uint256 amount);
    event AutoRewardDistributed(address indexed meme, address indexed user, uint256 amount);
    event Reward(address indexed meme, uint256 amount);
    event QuarterUpdated(address indexed token, uint256 quarter, uint256 apr);
    event EarlyUnstakePenalty(address indexed user, address meme, uint256 penaltyAmount);
    event AutoCompoundToggled(address indexed user, address meme, bool enabled);
    event TokenQuarterConfigSet(address indexed token);
    
    // Set custom quarter configuration for a specific token
    function setTokenQuarterConfig(
        address _token
    ) external {
        require(msg.sender == address(factory), "Not authorized");
        require(_token != address(0), "Invalid token address");
        
        TokenQuarterConfig storage config = tokenQuarterConfigs[_token];
        config.quarterlyAPR = defaultQuarterlyAPR;
        config.quarterDuration = DEFAULT_QUARTER_DURATION;
        config.stakingStartTime = block.timestamp;
        config.currentQuarter = 0;
        config.hasCustomConfig = true;
        
        // Initialize token-specific staking periods
        _initializeTokenStakingPeriods(_token);
        
        emit TokenQuarterConfigSet(_token);
    }
    
    function _initializeTokenStakingPeriods(address _token) internal {
        TokenQuarterConfig storage config = tokenQuarterConfigs[_token];
        
        for (uint256 i = 0; i < 4; i++) {
            tokenStakingPeriods[_token][i] = TokenStakingPeriod({
                startTime: config.stakingStartTime + (i * config.quarterDuration),
                endTime: config.stakingStartTime + ((i + 1) * config.quarterDuration),
                duration: config.quarterDuration,
                apr: config.quarterlyAPR[i],
                active: i == 0 // Only first quarter is initially active
            });
        }
    }
    
    function _updateTokenQuarter(address _token) internal {
        TokenQuarterConfig storage config = tokenQuarterConfigs[_token];
        uint256 newQuarter = (block.timestamp - config.stakingStartTime) / config.quarterDuration;
        
        if (newQuarter > config.currentQuarter && newQuarter < 4) {
            tokenStakingPeriods[_token][config.currentQuarter].active = false;
            config.currentQuarter = newQuarter;
            tokenStakingPeriods[_token][config.currentQuarter].active = true;
            
            // Update token reward rate
            _updateTokenRewardRate(_token);
            
            emit QuarterUpdated(_token, config.currentQuarter, config.quarterlyAPR[config.currentQuarter]);
        }
    }
    
    function _updateGlobalQuarter() internal {
        uint256 newQuarter = (block.timestamp - stakingStartTime) / DEFAULT_QUARTER_DURATION;
        if (newQuarter > globalCurrentQuarter && newQuarter < 4) {
            globalStakingPeriods[globalCurrentQuarter].active = false;
            globalCurrentQuarter = newQuarter;
            globalStakingPeriods[globalCurrentQuarter].active = true;
            
            // Update global reward rates for all tokens without custom configs
            _updateGlobalRewardRates();
            
            emit QuarterUpdated(address(0), globalCurrentQuarter, defaultQuarterlyAPR[globalCurrentQuarter]);
        }
    }
    
    function _updateGlobalRewardRates() internal {
        // Update reward rates for all active tokens
        MemedFactory.TokenDataView[] memory allTokens = factory.getTokens(address(0));
        for (uint256 i = 0; i < allTokens.length; i++) {
            if (allTokens[i].token != address(0) && !allTokens[i].fairLaunchActive) {
                if (!tokenQuarterConfigs[allTokens[i].token].hasCustomConfig) {
                    _updateTokenRewardRate(allTokens[i].token);
                }
            }
        }
    }
    
    function getCurrentAPR(address _token) public view returns (uint256) {
        if (tokenQuarterConfigs[_token].hasCustomConfig) {
            TokenQuarterConfig storage config = tokenQuarterConfigs[_token];
            uint256 quarter = (block.timestamp - config.stakingStartTime) / config.quarterDuration;
            if (quarter >= 4) {
                return config.quarterlyAPR[3]; // Use last quarter's rate after year 1
            }
            return config.quarterlyAPR[quarter];
        } else {
            // Use global system
            uint256 quarter = (block.timestamp - stakingStartTime) / DEFAULT_QUARTER_DURATION;
            if (quarter >= 4) {
                return defaultQuarterlyAPR[3]; // Use last quarter's rate after year 1
            }
            return defaultQuarterlyAPR[quarter];
        }
    }
    
    function _updateTokenRewardRate(address _token) internal {
        TokenStakingInfo storage info = tokenStakingInfo[_token];
        uint256 currentAPR = getCurrentAPR(_token);
        
        if (info.totalStaked > 0) {
            // Calculate rewards per second per token based on APR
            // APR is in basis points, so divide by 10000 and then by seconds in year
            info.globalRewardRate = (currentAPR * 1e18) / (10000 * 365 days);
        } else {
            info.globalRewardRate = 0;
        }
        
        info.lastGlobalRewardUpdate = block.timestamp;
    }
    
    function _updateUserRewards(address _token, address _user) internal {
        Stake storage userStake = stakes[_token][_user];
        TokenStakingInfo storage info = tokenStakingInfo[_token];
        
        if (userStake.amount == 0) return;
        
        uint256 timeSinceLastUpdate = block.timestamp - userStake.lastRewardUpdate;
        if (timeSinceLastUpdate == 0) return;
        
        // Calculate automatic rewards based on current APR and time elapsed
        uint256 currentAPR = getCurrentAPR(_token);
        uint256 rewardAmount = (userStake.amount * currentAPR * timeSinceLastUpdate) / (365 days * 10000);
        
        if (userStake.autoCompound) {
            // Auto-compound: add rewards to staked amount
            userStake.amount += rewardAmount;
            info.totalStaked += rewardAmount;
        } else {
            // Accumulate rewards for claiming
            userStake.pendingRewards += rewardAmount;
        }
        
        userStake.accumulatedRewards += rewardAmount;
        userStake.lastRewardUpdate = block.timestamp;
        
        emit AutoRewardDistributed(_token, _user, rewardAmount);
    }
    

    function _updateAllStakersRewards(address _token) internal {
        address[] storage tokenStakers = stakers[_token];
        for (uint256 i = 0; i < tokenStakers.length; i++) {
            _updateUserRewards(_token, tokenStakers[i]);
        }
    }

    function stake(address meme, uint256 amount, bool _autoCompound) external nonReentrant {
        require(amount > 0, "Stake more than zero");
        require(IERC20(meme).balanceOf(msg.sender) >= amount, "Not enough tokens");
        
        // Update quarter if needed
        _updateTokenQuarter(meme);
        
        // Update all stakers' rewards before modifying stakes
        _updateAllStakersRewards(meme);
        
        IERC20(meme).transferFrom(msg.sender, address(this), amount);
        
        TokenStakingInfo storage info = tokenStakingInfo[meme];
        
        if(stakes[meme][msg.sender].amount == 0) {
            stakers[meme].push(msg.sender);
            stakes[meme][msg.sender].stakeTime = block.timestamp;
            stakes[meme][msg.sender].lastRewardUpdate = block.timestamp;
            stakes[meme][msg.sender].autoCompound = _autoCompound;
        }
        
        stakes[meme][msg.sender].amount += amount;
        info.totalStaked += amount;
        
        // Update token reward rate
        _updateTokenRewardRate(meme);
        
        MemedFactory.HeatUpdate[] memory heatUpdate = new MemedFactory.HeatUpdate[](1);
        heatUpdate[0] = MemedFactory.HeatUpdate({
            token: meme,
            heat: amount / TOKENS_PER_HEAT,
            minusHeat: false
        });
        factory.updateHeat(heatUpdate);
        
        emit Staked(msg.sender, meme, amount, getCurrentAPR(meme), _autoCompound);
    }

    function unstake(address meme, uint256 amount) external nonReentrant {
        require(amount > 0, "Nothing to unstake");
        require(stakes[meme][msg.sender].amount >= amount, "Not enough staked");
        
        // Check that user isn't trying to unstake tokens allocated to battles
        uint256 availableToUnstake = stakes[meme][msg.sender].amount - memedBattle.getUserAllocatedToBattle(msg.sender, meme);
        require(availableToUnstake >= amount, "Cannot unstake tokens allocated to battles");
        
        // Update rewards before unstaking
        _updateUserRewards(meme, msg.sender);
        
        TokenStakingInfo storage info = tokenStakingInfo[meme];
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
        info.totalStaked -= amount;
        
        if(stakes[meme][msg.sender].amount == 0) {
            for(uint i = 0; i < stakers[meme].length; i++) {
                if(stakers[meme][i] == msg.sender) {
                    stakers[meme][i] = stakers[meme][stakers[meme].length - 1];
                    stakers[meme].pop();
                    break;
                }
            }
        }
        
        // Update token reward rate
        _updateTokenRewardRate(meme);
        
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
    
    function claimReward(address meme) external nonReentrant {
        _updateUserRewards(meme, msg.sender);
        
        uint256 amount = stakes[meme][msg.sender].pendingRewards;
        if(memedBattle.getUserClaimableRewards(msg.sender, meme) > 0) {
            amount += memedBattle.getUserClaimableRewards(msg.sender, meme);
            memedBattle.claimRewards(msg.sender, meme);
        }
        require(amount > 0, "Nothing to claim");
        require(IERC20(meme).balanceOf(address(this)) >= amount, "Not enough tokens in contract");
        
        stakes[meme][msg.sender].pendingRewards = 0;
        IERC20(meme).transfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, meme, amount);
    }
    
    function toggleAutoCompound(address meme) external {
        require(stakes[meme][msg.sender].amount > 0, "Not staking this token");
        
        // Update rewards before changing compound setting
        _updateUserRewards(meme, msg.sender);
        
        stakes[meme][msg.sender].autoCompound = !stakes[meme][msg.sender].autoCompound;
        
        emit AutoCompoundToggled(msg.sender, meme, stakes[meme][msg.sender].autoCompound);
    }
    
    function unallocateFromBattle(address meme, uint256 amount) external {
        require(msg.sender == address(memedBattle), "Not authorized");
        IERC20(meme).transfer(address(factory), amount);
    }
    
    function getPendingRewards(address meme, address user) public view returns (uint256) {
        Stake memory userStake = stakes[meme][user];
        if (userStake.amount == 0) return userStake.pendingRewards;
        
        uint256 timeSinceLastUpdate = block.timestamp - userStake.lastRewardUpdate;
        uint256 currentAPR = getCurrentAPR(meme);
        uint256 newRewards = (userStake.amount * currentAPR * timeSinceLastUpdate) / (365 days * 10000);
        
        return userStake.pendingRewards + newRewards;
    }
    
    function getStakeInfo(address meme, address user) external view returns (
        uint256 amount,
        uint256 pendingRewards,
        uint256 accumulatedRewards,
        uint256 stakeTime,
        uint256 currentAPR,
        bool autoCompound
    ) {
        Stake memory userStake = stakes[meme][user];
        uint256 pending = getPendingRewards(meme, user);
        
        return (
            userStake.amount,
            pending,
            userStake.accumulatedRewards,
            userStake.stakeTime,
            getCurrentAPR(meme),
            userStake.autoCompound
        );
    }
    
    function getDetailedStakeInfo(address meme, address user) external view returns (
        uint256 totalStaked,
        uint256 allocatedToBattle,
        uint256 availableForAllocation,
        uint256 availableToUnstake,
        uint256 pendingRewards,
        uint256 accumulatedRewards,
        uint256 stakeTime,
        uint256 currentAPR,
        bool autoCompound
    ) {
        Stake memory userStake = stakes[meme][user];
        uint256 pending = getPendingRewards(meme, user);
        uint256 availableForAlloc = userStake.amount > memedBattle.getUserAllocatedToBattle(user, meme) ? userStake.amount - memedBattle.getUserAllocatedToBattle(user, meme) : 0;
        
        return (
            userStake.amount,
            memedBattle.getUserAllocatedToBattle(user, meme),
            availableForAlloc,
            availableForAlloc, // availableToUnstake is same as availableForAllocation
            pending,
            userStake.accumulatedRewards,
            userStake.stakeTime,
            getCurrentAPR(meme),
            userStake.autoCompound
        );
    }
    
    function getAvailableToken(address meme, address user) external view returns (uint256) {
        return stakes[meme][user].amount - memedBattle.getUserAllocatedToBattle(user, meme);
    }
    
    function getTokenStakingInfo(address token) external view returns (
        uint256 totalStaked,
        uint256 totalRewardsDistributed,
        uint256 globalRewardRate,
        uint256 currentAPR
    ) {
        TokenStakingInfo memory info = tokenStakingInfo[token];
        return (
            info.totalStaked,
            info.totalRewardsDistributed,
            info.globalRewardRate,
            getCurrentAPR(token)
        );
    }

    function getStakers(address meme) external view returns (address[] memory) {
        return stakers[meme];
    }
    

    function setFactoryAndBattle(address payable _factory, address _battle) external onlyOwner {
        require(address(factory) == address(0) && address(memedBattle) == address(0), "Already set");
        factory = MemedFactory(_factory);
        memedBattle = IMemedBattle(_battle);
    }

    function isRewardable(address meme) external view returns (bool) {
        return (IERC20(meme).balanceOf(address(this)) >= (MAX_REWARD * 3) / 100) && (stakers[meme].length > 0);
    }
    
    function getQuarterInfo(uint256 quarter) external view returns (TokenStakingPeriod memory) {
        require(quarter < 4, "Invalid quarter");
        return globalStakingPeriods[quarter];
    }
}
