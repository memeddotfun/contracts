// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMemedToken {
    function LP_ALLOCATION() external view returns (uint256);
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}
