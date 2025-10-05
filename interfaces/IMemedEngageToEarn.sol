// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMemedEngageToEarn {
    function getUserEngagementReward(address _user, address _token) external view returns (uint256);
    function isRewardable(address _token) external view returns (bool);
    function registerEngagementReward(address _token) external;
    function getBattleRewardPool(address _token) external view returns (uint256);
    function transferBattleRewards(address _loser, address _winner, uint256 _amount) external returns (uint256);
    function claimBattleRewards(address _token, address _winner, uint256 _amount) external;
}
