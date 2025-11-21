// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

/// @title IWETH
/// @notice Interface for Wrapped ETH
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}
