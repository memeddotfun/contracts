// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MemedBattle.sol";

contract MemedWarriorNFT is ERC721, Ownable, ReentrancyGuard {
    // Base price and dynamic pricing constants from Memed.md specification
    uint256 public constant BASE_PRICE = 5000 * 1e18; // 5,000 MEME base price
    uint256 public constant PRICE_INCREMENT = 100 * 1e18; // +100 MEME per 10,000 Heat Score
    uint256 public constant HEAT_THRESHOLD = 10000; // 10,000 Heat Score threshold
    
    IMemedFactory public immutable factory;
    MemedBattle public immutable memedBattle;
    address public immutable memedToken; // The main MEME token address
    
    uint256 public currentTokenId;

    // NFT data structure
    struct WarriorData {
        uint256 tokenId;
        address owner;
        uint256 mintPrice;
        uint256 mintedAt;
        bool burned;
    }
    
    mapping(uint256 => WarriorData) public warriors;
    mapping(address => uint256[]) public userNFTs; // Track user's NFTs
    
    event WarriorMinted(
        uint256 indexed tokenId, 
        address indexed owner,
        uint256 price
    );

    event WarriorBurned(
        uint256 indexed tokenId, 
        address indexed owner
    );
    
    event WarriorGetBack(
        uint256 indexed tokenId, 
        address indexed owner
    );
    
    event TokensBurned(uint256 amount, uint256 totalPlatformHeat);
    
    event MintingFeeCollected(
        address indexed user,
        uint256 feeAmount,
        uint256 tokenId
    );
    
    constructor(
        address _memedToken,
        address _factory,
        address _memedBattle
    ) ERC721("Memed Warrior", "WARRIOR") {
        memedToken = _memedToken;
        factory = IMemedFactory(_factory);
        memedBattle = MemedBattle(_memedBattle);
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
        
        // Check and transfer MEME tokens
        require(
            IERC20(memedToken).balanceOf(msg.sender) >= price,
            "Insufficient MEME tokens"
        );
        
        require(
            IERC20(memedToken).transferFrom(msg.sender, address(this), price),
            "Transfer failed"
        );
        
        // Calculate 1% platform fee
        uint256 platformFee = (price * factory.platformFeePercentage()) / factory.feeDenominator();
        uint256 amountToBurn = price - platformFee;
        
        // Send platform fee to factory owner (if fee > 0)
        if (platformFee > 0) {
            address factoryOwner = factory.owner();
            IERC20(memedToken).transfer(address(factory), platformFee);
            factory.swapExactForNativeToken(platformFee, memedToken, factoryOwner);
        }
        
        // Burn the remaining MEME tokens (99% as per new specification)
        _burnTokens(amountToBurn);
        
        // Mint NFT
        currentTokenId++;
        uint256 tokenId = currentTokenId;
        
        // Emit fee collection event (if fee > 0)
        if (platformFee > 0) {
            emit MintingFeeCollected(msg.sender, platformFee, tokenId);
        }
        
        _safeMint(msg.sender, tokenId);
        
        // Store warrior data
        warriors[tokenId] = WarriorData({
            tokenId: tokenId,
            owner: msg.sender,
            mintPrice: price,
            mintedAt: block.timestamp,
            burned: false
        });
        
        userNFTs[msg.sender].push(tokenId);
        
        emit WarriorMinted(tokenId, msg.sender, price);
        
        return tokenId;
    }
    
    /**
     * @dev Burn NFT (called by user when they want to allocate NFTs to a battle)
     */
    function _burnWarrior(uint256 _tokenId) internal {
        require(_exists(_tokenId), "NFT does not exist");
        require(!warriors[_tokenId].burned, "NFT already burned");
        
        address owner = ownerOf(_tokenId);
        warriors[_tokenId].burned = true;
        
        // Burn the NFT
        _burn(_tokenId);
        
        emit WarriorBurned(_tokenId, owner);
    }

    /** Get back the warrior NFTs to the user if they win the battle
     * @dev Get back the warrior NFTs to the user if they win the battle
     */
    function getBackWarrior(uint256 _battleId) external {
        MemedBattle.Battle memory battle = memedBattle.getBattle(_battleId);
        require(battle.winner == memedToken, "Not the winner");
        MemedBattle.UserBattleAllocation memory allocation = memedBattle.getBattleAllocations(_battleId, msg.sender, memedToken);
        require(allocation.nftsIds.length > 0, "No allocation found");
        memedBattle.getBackWarrior(_battleId, msg.sender);
        for (uint256 i = 0; i < allocation.nftsIds.length; i++) {
            if(factory.getMemedEngageToEarn().getUserEngagementReward(msg.sender, memedToken) > 0) {
                continue;
            }
            uint256 tokenId = allocation.nftsIds[i];
            _safeMint(msg.sender, tokenId);
            warriors[tokenId].burned = false;
            emit WarriorGetBack(tokenId, msg.sender);
        }
    }

    function allocateNFTsToBattle(uint256 _battleId, address _user, address _supportedMeme, uint256[] calldata _nftsIds) external {
        for (uint256 i = 0; i < _nftsIds.length; i++) {
            _burnWarrior(_nftsIds[i]);
        }
        memedBattle.allocateNFTsToBattle(_battleId, _user, _supportedMeme, _nftsIds);
    }
    
    /**
     * @dev Check if user owns any active Warrior NFTs
     */
    function hasActiveWarrior(address _user) external view returns (bool) {
        uint256[] memory nfts = userNFTs[_user];
        for (uint256 i = 0; i < nfts.length; i++) {
            if (_exists(nfts[i]) && !warriors[nfts[i]].burned) {
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
            if (_exists(userTokens[i]) && !warriors[userTokens[i]].burned) {
                activeCount++;
            }
        }
        
        // Build active NFTs array
        uint256[] memory activeNFTs = new uint256[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < userTokens.length; i++) {
            if (_exists(userTokens[i]) && !warriors[userTokens[i]].burned) {
                activeNFTs[index] = userTokens[i];
                index++;
            }
        }
        
        return activeNFTs;
    }
    
    /**
     * @dev Burn MEME tokens (send to zero address)
     */
    function _burnTokens(uint256 _amount) internal {
        // Transfer to zero address = burn
        require(
            IERC20(memedToken).transfer(address(0), _amount),
            "Burn failed"
        );
        
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
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
        
        if (from != address(0) && to != address(0)) {
            // Update warrior owner data
            warriors[tokenId].owner = to;
            
            // Update user NFT tracking
            _removeFromUserNFTs(from, tokenId);
            userNFTs[to].push(tokenId);
        }
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
    
    /**
     * @dev Calculate platform fee for a given price
     */
    function calculateMintingFee(uint256 _price) external view returns (uint256) {
        return (_price * factory.platformFeePercentage()) / factory.feeDenominator();
    }
}
