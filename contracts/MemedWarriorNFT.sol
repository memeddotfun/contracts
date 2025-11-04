// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IMemedFactory.sol";
import "../interfaces/IMemedBattle.sol";
import "../interfaces/IMemedEngageToEarn.sol";
import "../structs/WarriorStructs.sol";

interface IMemedToken is IERC20 {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

contract MemedWarriorNFT is ERC721, Ownable, ReentrancyGuard {
    // Base price and dynamic pricing constants from Memed.md specification
    uint256 public constant BASE_PRICE = 5000 * 1e18; // 5,000 MEME base price
    uint256 public constant PRICE_INCREMENT = 100 * 1e18; // +100 MEME per 10,000 Heat Score
    uint256 public constant HEAT_THRESHOLD = 10000; // 10,000 Heat Score threshold
    
    IMemedFactory public immutable factory;
    IMemedBattle public immutable memedBattle;
    address public immutable memedToken; // The main MEME token address
    
    uint256 public currentTokenId;

    // NFT data structure
    
    mapping(uint256 => WarriorData) public warriors;
    mapping(address => uint256[]) public userNFTs; // Track user's NFTs
    
    event WarriorMinted(
        uint256 indexed tokenId, 
        address indexed owner,
        uint256 price
    );

    event WarriorAllocated(
        uint256 indexed tokenId, 
        address indexed owner
    );
    
    event WarriorGetBack(
        uint256 indexed tokenId, 
        address indexed owner
    );
    
    event TokensBurned(uint256 amount, uint256 totalPlatformHeat);

    constructor(
        address _memedToken,
        address _memedBattle,
        address _factory
    ) ERC721("Memed Warrior", "WARRIOR") Ownable(msg.sender) {
        memedToken = _memedToken;
        factory = IMemedFactory(_factory);
        memedBattle = IMemedBattle(_memedBattle);
    }
    
    /**
     * @dev Calculate current NFT price based on platform Heat Score
     * Price = 5,000 MEME + (100 MEME × (Total Heat Score ÷ 10,000))
     */
    function getCurrentPrice() public view returns (uint256) {
        uint256 totalHeat = factory.getHeat(memedToken);
        uint256 priceBoost = (totalHeat / HEAT_THRESHOLD) * PRICE_INCREMENT;
        return BASE_PRICE + priceBoost;
    }
    
    /**
     * @dev Mint a Warrior NFT - requires MEME tokens, 1% fee collected, rest burned
     */
    function mintWarrior() external nonReentrant returns (uint256) {
        uint256 price = getCurrentPrice();
        
        // Check balance
        require(
            IERC20(memedToken).balanceOf(msg.sender) >= price,
            "Insufficient MEME tokens"
        );
        
        // Burn tokens directly from user (requires approval)
        _burnTokens(msg.sender, price);
        
        // Mint NFT
        currentTokenId++;
        uint256 tokenId = currentTokenId;
 
        _safeMint(msg.sender, tokenId);
        
        // Store warrior data
        warriors[tokenId] = WarriorData({
            tokenId: tokenId,
            owner: msg.sender,
            mintPrice: price,
            mintedAt: block.timestamp,
            allocated: false
        });
        
        userNFTs[msg.sender].push(tokenId);
        
        emit WarriorMinted(tokenId, msg.sender, price);
        
        return tokenId;
    }
    
    /**
     * @dev Allocate NFT (called by user when they want to allocate NFTs to a battle)
     */
    function _allocateWarrior(uint256 _tokenId) internal {
        require(_exists(_tokenId), "NFT does not exist");
        require(!warriors[_tokenId].allocated, "NFT already allocated");
        
        address owner = ownerOf(_tokenId);
        warriors[_tokenId].allocated = true;
        
        
        emit WarriorAllocated(_tokenId, owner);
    }

    /** Get back the warrior NFTs to the user if they win the battle
     * @dev Get back the warrior NFTs to the user if they win the battle
     */
    function getBackWarrior(uint256 _battleId) external {
        Battle memory battle = memedBattle.getBattle(_battleId);
        require(battle.winner == memedToken, "Not the winner");
        UserBattleAllocation memory allocation = memedBattle.getBattleAllocations(_battleId, msg.sender, memedToken);
        require(allocation.nftsIds.length > 0, "No allocation found");
        memedBattle.getBackWarrior(_battleId, msg.sender);
        for (uint256 i = 0; i < allocation.nftsIds.length; i++) {
            if(IMemedEngageToEarn(factory.getMemedEngageToEarn()).getUserEngagementReward(msg.sender, memedToken) > 0) {
                continue;
            }
            warriors[allocation.nftsIds[i]].allocated = false;
        }
    }

    function allocateNFTsToBattle(uint128 _battleId, address _user, address _supportedMeme, uint256[] calldata _nftsIds) external {
        for (uint256 i = 0; i < _nftsIds.length; i++) {
            _allocateWarrior(_nftsIds[i]);
        }
        memedBattle.allocateNFTsToBattle(_battleId, _user, _supportedMeme, _nftsIds);
    }
    
    /**
     * @dev Check if user owns any active Warrior NFTs
     */
    function hasActiveWarrior(address _user) external view returns (bool) {
        uint256[] memory nfts = userNFTs[_user];
        for (uint256 i = 0; i < nfts.length; i++) {
            if (_exists(nfts[i])) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @dev Get user's active NFTs
     */
    function getUserActiveNFTs(address _user) external view returns (uint256[] memory) {
        uint256[] memory userTokens = userNFTs[_user];
        uint256 activeCount = 0;
        
        // Count active NFTs
        for (uint256 i = 0; i < userTokens.length; i++) {
            if (_exists(userTokens[i])) {
                activeCount++;
            }
        }
        
        // Build active NFTs array
        uint256[] memory activeNFTs = new uint256[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < userTokens.length; i++) {
            if (_exists(userTokens[i])) {
                activeNFTs[index] = userTokens[i];
                index++;
            }
        }
        
        return activeNFTs;
    }
    
    /**
    * @dev Burn MEME tokens from user using burnFrom (requires approval)
     */
    function _burnTokens(address _from, uint256 _amount) internal {
        IMemedToken(memedToken).burnFrom(_from, _amount);
        emit TokensBurned(_amount, factory.getHeat(memedToken));
    }

    function _removeFromUserNFTs(address _user, uint256 _tokenId) internal {
        uint256[] storage nfts = userNFTs[_user];
        for (uint256 i = 0; i < nfts.length; i++) {
            if (nfts[i] == _tokenId) {
                nfts[i] = nfts[nfts.length - 1];
                nfts.pop();
                break;
            }
        }
    }
    
    /**
     * @dev Override transfer to update ownership tracking
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        
        if (from != address(0) && to != address(0)) {
            // Update warrior owner data
            warriors[tokenId].owner = to;
            
            // Update user NFT tracking
            _removeFromUserNFTs(from, tokenId);
            userNFTs[to].push(tokenId);
        }
        
        return from;
    }
    
    function getWarriorMintedBeforeByUser(address _user, uint256 _timestamp) external view returns (uint256) {
        uint256[] memory nfts = userNFTs[_user];
        uint256 count = 0;
        for (uint256 i = 0; i < nfts.length; i++) {
            if (warriors[nfts[i]].mintedAt < _timestamp) {
                count++;
            }
        }
        return count;
    }

    function _exists(uint256 _tokenId) internal view returns (bool) {
        return _tokenId <= currentTokenId;
    }
}
