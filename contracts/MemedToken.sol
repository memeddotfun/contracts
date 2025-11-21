// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title Memed Token
/// @notice ERC20 token with fixed supply and token distribution
contract MemedToken is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = 1000000000 * 1e18;

    uint256 public constant FAIR_LAUNCH_ALLOCATION = 150000000 * 1e18;
    uint256 public constant LP_ALLOCATION = 100000000 * 1e18;
    uint256 public constant ENGAGEMENT_REWARDS_ALLOCATION = 550000000 * 1e18;
    uint256 public constant CREATOR_INCENTIVES_ALLOCATION = 200000000 * 1e18;

    constructor(
        string memory _name,
        string memory _ticker,
        address _factoryContract,
        address _engageToEarnContract,
        address _memedTokenSale
    ) ERC20(_name, _ticker) Ownable(msg.sender) {
        _mint(_factoryContract, LP_ALLOCATION);
        _mint(
            _engageToEarnContract,
            ENGAGEMENT_REWARDS_ALLOCATION + CREATOR_INCENTIVES_ALLOCATION
        );
        _mint(_memedTokenSale, FAIR_LAUNCH_ALLOCATION);
    }

    /// @notice Allows anyone to burn their own tokens
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Allows burning tokens from an account that has approved the caller
    /// @param account The account to burn tokens from
    /// @param amount The amount of tokens to burn
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }
}
