// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMemedToken {
    function claim(address _to, uint256 _amount) external;
    function allocateLp() external;
    function isLpAllocated() external view returns (bool);
    function LP_ALLOCATION() external view returns (uint256);
    function isRewardable() external view returns (bool);
    function unlockCreatorIncentives() external;
}
