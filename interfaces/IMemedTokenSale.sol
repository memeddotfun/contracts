// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMemedTokenSale {
    function startFairLaunch(address _creator) external returns (uint256);
    function tokenIdByAddress(address _token) external view returns (uint256);
    function isMintable(address _creator) external view returns (bool);
    function INITIAL_SUPPLY() external view returns (uint256);
}
