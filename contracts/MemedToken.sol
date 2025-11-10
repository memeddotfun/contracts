// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MemedToken is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = 1000000000 * 1e18; // 1B (100%)
    
    // Token distribution according to Memed.fun v2.3 tokenomics
    uint256 public constant FAIR_LAUNCH_ALLOCATION = 200000000 * 1e18; // 200M (20%)
    uint256 public constant LP_ALLOCATION = 100000000 * 1e18; // 100M (10%)
    uint256 public constant ENGAGEMENT_REWARDS_ALLOCATION = 500000000 * 1e18; // 500M (50%)
    uint256 public constant CREATOR_INCENTIVES_ALLOCATION = 200000000 * 1e18; // 200M (20%)
    
    constructor(
        string memory _name,
        string memory _ticker,
        address _factoryContract,
        address _engageToEarnContract,
        address _memedTokenSale
    ) ERC20(_name, _ticker) Ownable(msg.sender) {
        _mint(_factoryContract, LP_ALLOCATION);
        _mint(_engageToEarnContract, ENGAGEMENT_REWARDS_ALLOCATION+CREATOR_INCENTIVES_ALLOCATION);
        _mint(_memedTokenSale, FAIR_LAUNCH_ALLOCATION);
    }
    
    /**
     * @dev Allows anyone to burn their own tokens
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Allows burning tokens from an account that has approved the caller
     */
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }
}
