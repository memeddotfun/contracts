// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMemedToken {
    function allocateLp() external;
    function isLpAllocated() external view returns (bool);
    function LP_ALLOCATION() external view returns (uint256);
    function isRewardable() external view returns (bool);
    function unlockCreatorIncentives() external;
    function claimUnclaimedTokens(address to) external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}
