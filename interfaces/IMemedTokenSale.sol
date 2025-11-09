// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../structs/TokenSaleStructs.sol";

interface IMemedTokenSale {
    function startFairLaunch(address _creator) external returns (uint256);
    function tokenIdByAddress(address _token) external view returns (uint256);
    function isMintable(address _creator) external view returns (bool);
    function completeFairLaunch(uint256 _id, address _token, address _pair) external;
    function getFairLaunchData(uint256 _id) external view returns (FairLaunchStatus, uint256);
}
