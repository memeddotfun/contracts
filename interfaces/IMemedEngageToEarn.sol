// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMemedEngageToEarn {
    function ENGAGEMENT_REWARDS_PER_NFT_PERCENTAGE()
        external
        view
        returns (uint256);
    function isRewardable(address _token) external view returns (bool);
    function registerEngagementReward(address _token) external;
    function getBattleRewardPool(
        address _token
    ) external view returns (uint256);
    function transferBattleRewards(
        address _loser,
        address _winner,
        uint256 _amount
    ) external returns (uint256);
    function ENGAGEMENT_REWARDS_CHANGE() external view returns (uint256);
    function isCreatorRewardable(address _token) external view returns (bool);
    function unlockCreatorIncentives(address _token) external;
    function claimCreatorIncentives(address _token) external;
    function claimUnclaimedTokens(address _token, address to) external;
}
