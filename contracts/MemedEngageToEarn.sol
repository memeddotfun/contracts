// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MemedEngageToEarn is Ownable {
    uint256 public constant MAX_REWARD = 150_000_000 * 1e18; // 150M tokens for engagement rewards
    uint256 public constant MAX_ENGAGE_USER_REWARD = (MAX_REWARD * 2) / 100;
    uint256 public constant MAX_ENGAGE_CREATOR_REWARD = (MAX_REWARD * 1) / 100;
    uint256 public constant VESTING_DURATION = 15 days; // 15 days linear vesting
    uint256 public constant INSTANT_PERCENTAGE = 50; // 50% instant, 50% vested
    
    address public factory;

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 startTime;
        uint256 claimedAmount;
        bool active;
    }

    mapping(address => mapping(uint256 => bytes32)) public engagements;
    mapping(address => mapping(uint256 => bool)) public index;
    mapping(address => uint256) availableIndex;
    mapping(address => uint256) public unlockedAmount;
    mapping(bytes32 => bool) public claimed;
    
    // Creator vesting schedules (25% monthly over 4 months)
    mapping(address => mapping(address => VestingSchedule[])) public creatorVesting; // token => creator => schedules
    mapping(address => mapping(address => uint256)) public creatorVestingCount;
    
    // User engagement vesting (50% instant, 50% over 15 days)
    mapping(address => mapping(address => VestingSchedule[])) public userVesting; // token => user => schedules
    mapping(address => mapping(address => uint256)) public userVestingCount;

    event Claimed(address indexed user, uint256 amount, uint256 index);
    event SetMerkleRoot(address indexed token, uint256 index, bytes32 root);
    event Reward(address indexed token, uint256 userAmount, uint256 creatorAmount, uint256 index);
    event CreatorVestingCreated(address indexed token, address indexed creator, uint256 amount, uint256 startTime);
    event UserVestingCreated(address indexed token, address indexed user, uint256 amount, uint256 startTime);
    event VestedTokensClaimed(address indexed user, address indexed token, uint256 amount);
    
    function claim(
        address _token,
        uint256 _amount,
        uint256 _index,
        bytes32[] calldata _proof
    ) external {
        bytes32 leaf = keccak256(abi.encodePacked(_token, msg.sender, _amount, _index));
        require(MerkleProof.verify(_proof, engagements[_token][_index], leaf), "Invalid proof");
        require(!claimed[leaf], "Already claimed");
        require(unlockedAmount[_token] >= _amount, "Not enough tokens");

        claimed[leaf] = true;
        unlockedAmount[_token] -= _amount;
        
        // Split into instant and vested amounts
        uint256 instantAmount = (_amount * INSTANT_PERCENTAGE) / 100;
        uint256 vestedAmount = _amount - instantAmount;
        
        // Transfer instant amount
        IERC20(_token).transfer(msg.sender, instantAmount);
        
        // Create vesting schedule for remaining amount
        if (vestedAmount > 0) {
            _createUserVesting(_token, msg.sender, vestedAmount);
        }
        
        emit Claimed(msg.sender, _amount, _index);
    }
    
    function _createUserVesting(address _token, address _user, uint256 _amount) internal {
        VestingSchedule memory schedule = VestingSchedule({
            totalAmount: _amount,
            startTime: block.timestamp,
            claimedAmount: 0,
            active: true
        });
        
        userVesting[_token][_user].push(schedule);
        userVestingCount[_token][_user]++;
        
        emit UserVestingCreated(_token, _user, _amount, block.timestamp);
    }
    
    function _createCreatorVesting(address _token, address _creator, uint256 _amount) internal {
        // Creator vesting: 25% monthly over 4 months
        uint256 monthlyAmount = _amount / 4;
        
        for (uint i = 0; i < 4; i++) {
            VestingSchedule memory schedule = VestingSchedule({
                totalAmount: monthlyAmount,
                startTime: block.timestamp + (i * 30 days), // Monthly releases
                claimedAmount: 0,
                active: true
            });
            
            creatorVesting[_token][_creator].push(schedule);
        }
        
        creatorVestingCount[_token][_creator] += 4;
        emit CreatorVestingCreated(_token, _creator, _amount, block.timestamp);
    }
    
    function claimVestedTokens(address _token) external {
        uint256 totalClaimable = 0;
        
        // Check user vesting schedules
        VestingSchedule[] storage userSchedules = userVesting[_token][msg.sender];
        for (uint i = 0; i < userSchedules.length; i++) {
            if (userSchedules[i].active) {
                uint256 claimable = _calculateClaimableAmount(userSchedules[i], VESTING_DURATION);
                if (claimable > 0) {
                    totalClaimable += claimable;
                    userSchedules[i].claimedAmount += claimable;
                    
                    // Mark as inactive if fully claimed
                    if (userSchedules[i].claimedAmount >= userSchedules[i].totalAmount) {
                        userSchedules[i].active = false;
                    }
                }
            }
        }
        
        // Check creator vesting schedules
        VestingSchedule[] storage creatorSchedules = creatorVesting[_token][msg.sender];
        for (uint i = 0; i < creatorSchedules.length; i++) {
            if (creatorSchedules[i].active && block.timestamp >= creatorSchedules[i].startTime) {
                uint256 claimable = creatorSchedules[i].totalAmount - creatorSchedules[i].claimedAmount;
                if (claimable > 0) {
                    totalClaimable += claimable;
                    creatorSchedules[i].claimedAmount = creatorSchedules[i].totalAmount;
                    creatorSchedules[i].active = false;
                }
            }
        }
        
        require(totalClaimable > 0, "No tokens to claim");
        IERC20(_token).transfer(msg.sender, totalClaimable);
        
        emit VestedTokensClaimed(msg.sender, _token, totalClaimable);
    }
    
    function _calculateClaimableAmount(VestingSchedule memory _schedule, uint256 _vestingDuration) internal view returns (uint256) {
        if (!_schedule.active || block.timestamp < _schedule.startTime) {
            return 0;
        }
        
        uint256 elapsed = block.timestamp - _schedule.startTime;
        uint256 vestedAmount;
        
        if (elapsed >= _vestingDuration) {
            // Fully vested
            vestedAmount = _schedule.totalAmount;
        } else {
            // Linearly vested
            vestedAmount = (_schedule.totalAmount * elapsed) / _vestingDuration;
        }
        
        return vestedAmount > _schedule.claimedAmount ? vestedAmount - _schedule.claimedAmount : 0;
    }
    
    function getClaimableAmount(address _token, address _user) external view returns (uint256) {
        uint256 totalClaimable = 0;
        
        // Check user vesting schedules
        VestingSchedule[] storage userSchedules = userVesting[_token][_user];
        for (uint i = 0; i < userSchedules.length; i++) {
            if (userSchedules[i].active) {
                totalClaimable += _calculateClaimableAmount(userSchedules[i], VESTING_DURATION);
            }
        }
        
        // Check creator vesting schedules
        VestingSchedule[] storage creatorSchedules = creatorVesting[_token][_user];
        for (uint i = 0; i < creatorSchedules.length; i++) {
            if (creatorSchedules[i].active && block.timestamp >= creatorSchedules[i].startTime) {
                totalClaimable += creatorSchedules[i].totalAmount - creatorSchedules[i].claimedAmount;
            }
        }
        
        return totalClaimable;
    }
    
    function getUserVestingSchedules(address _token, address _user) external view returns (VestingSchedule[] memory) {
        return userVesting[_token][_user];
    }
    
    function getCreatorVestingSchedules(address _token, address _creator) external view returns (VestingSchedule[] memory) {
        return creatorVesting[_token][_creator];
    }

    function setMerkleRoot(address token, bytes32 root, uint256 _index) external onlyOwner {
        require(index[token][_index] == true, "Invalid index");
        engagements[token][_index] = root;
        index[token][_index] = false;
        emit SetMerkleRoot(token, _index, root);
    }

    function reward(address token, address _creator) external {
        require(msg.sender == factory, "unauthorized");
        require(IERC20(token).balanceOf(address(this)) >= (MAX_ENGAGE_USER_REWARD + MAX_ENGAGE_CREATOR_REWARD), "Not enough tokens");
        
        // Create vesting schedule for creator (instead of instant transfer)
        _createCreatorVesting(token, _creator, MAX_ENGAGE_CREATOR_REWARD);
        
        unlockedAmount[token] += MAX_ENGAGE_USER_REWARD;
        availableIndex[token]++;
        index[token][availableIndex[token]] = true;
        emit Reward(token, MAX_ENGAGE_USER_REWARD, MAX_ENGAGE_CREATOR_REWARD, availableIndex[token]);
    }   

    function isRewardable(address token) external view returns (bool) {
        return IERC20(token).balanceOf(address(this)) >= (MAX_ENGAGE_USER_REWARD + MAX_ENGAGE_CREATOR_REWARD);
    }

    function setFactory(address _factory) external onlyOwner {
        require(address(factory) == address(0), "Already set");
        factory = _factory;
    }
}