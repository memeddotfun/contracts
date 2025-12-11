// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

import "../interfaces/IMemedFactory.sol";
import "../interfaces/IMemedBattle.sol";
import "../interfaces/IMemedEngageToEarn.sol";
import "../interfaces/IMemedToken.sol";
import "../structs/WarriorStructs.sol";

/// @title Memed Warrior NFT
/// @notice ERC721 NFT for token warriors with dynamic pricing
contract MemedWarriorNFT is ERC721URIStorage, Ownable, ReentrancyGuard {
    uint256 public constant BASE_PRICE = 5000 * 1e18;
    uint256 public constant PRICE_INCREMENT = 100 * 1e18;
    uint256 public constant HEAT_THRESHOLD = 10000;

    IMemedFactory public immutable factory;
    IMemedBattle public immutable memedBattle;
    address public immutable memedToken;
    string public uri;

    uint256 public currentTokenId;

    mapping(uint256 => WarriorData) public warriors;
    mapping(address => uint256[]) public userNFTs;

    event WarriorMinted(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 price
    );

    event WarriorAllocated(uint256 indexed tokenId, address indexed owner);

    event WarriorGetBack(uint256 indexed tokenId, address indexed owner);

    event TokensBurned(uint256 amount, uint256 totalPlatformHeat);

    constructor(
        string memory _name,
        string memory _symbol,
        address _memedToken,
        address _memedBattle,
        address _factory,
        string memory _uri
    ) ERC721(_name, _symbol) Ownable(msg.sender) {
        memedToken = _memedToken;
        factory = IMemedFactory(_factory);
        memedBattle = IMemedBattle(_memedBattle);
        uri = _uri;
    }

    /// @notice Calculate current NFT price based on platform Heat Score
    /// @dev Price = 5,000 MEME + (100 MEME × (Total Heat Score ÷ 10,000))
    /// @return The current price in MEME tokens
    function getCurrentPrice() public view returns (uint256) {
        uint256 totalHeat = factory.getHeat(memedToken);
        uint256 priceBoost = (totalHeat / HEAT_THRESHOLD) * PRICE_INCREMENT;
        return BASE_PRICE + priceBoost;
    }

    /// @notice Mint a Warrior NFT - requires MEME tokens, 1% fee collected, rest burned
    /// @return The token ID of the minted NFT
    function mintWarrior() external nonReentrant returns (uint256) {
        uint256 price = getCurrentPrice();

        require(
            IERC20(memedToken).balanceOf(msg.sender) >= price,
            "Insufficient MEME tokens"
        );

        _burnTokens(msg.sender, price);

        currentTokenId++;
        uint256 tokenId = currentTokenId;
        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, uri);

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

    /// @notice Get back the warrior NFT after battle if returnable
    /// @param _nftId The NFT token ID to retrieve
    function getBackWarrior(uint256 _nftId) external {
        require(_exists(_nftId), "NFT does not exist");
        require(ownerOf(_nftId) == msg.sender, "Not the owner");
        require(warriors[_nftId].allocated, "NFT not allocated");
        (, bool isReturnable) = memedBattle.getNftRewardAndIsReturnable(
            memedToken,
            _nftId
        );
        require(isReturnable, "NFT not returnable");
        warriors[_nftId].allocated = false;
        emit WarriorGetBack(_nftId, msg.sender);
    }

    /// @notice Allocate NFTs to a battle
    /// @param _user The user address allocating the NFTs
    /// @param _nftsIds Array of NFT token IDs to allocate
    function allocateNFTsToBattle(
        address _user,
        uint256[] calldata _nftsIds
    ) external {
        require(msg.sender == address(memedBattle), "Only battle contract");
        for (uint256 i = 0; i < _nftsIds.length; i++) {
            require(_exists(_nftsIds[i]), "NFT does not exist");
            require(!warriors[_nftsIds[i]].allocated, "NFT already allocated");
            address owner = ownerOf(_nftsIds[i]);
            require(owner == _user, "Not the owner");
            warriors[_nftsIds[i]].allocated = true;
            emit WarriorAllocated(_nftsIds[i], owner);
        }
    }

    /// @notice Check if user owns any active Warrior NFTs
    /// @param _user The user address to check
    /// @return Whether the user has any active warriors
    function hasActiveWarrior(address _user) external view returns (bool) {
        uint256[] memory nfts = userNFTs[_user];
        for (uint256 i = 0; i < nfts.length; i++) {
            if (_exists(nfts[i])) {
                return true;
            }
        }
        return false;
    }

    /// @notice Get user's active NFTs
    /// @param _user The user address
    /// @return Array of active NFT token IDs owned by the user
    function getUserActiveNFTs(
        address _user
    ) external view returns (uint256[] memory) {
        uint256[] memory userTokens = userNFTs[_user];
        uint256 activeCount = 0;

        for (uint256 i = 0; i < userTokens.length; i++) {
            if (_exists(userTokens[i])) {
                activeCount++;
            }
        }

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

    /// @dev Burn MEME tokens from user using burnFrom
    /// @param _from The address to burn tokens from
    /// @param _amount The amount of tokens to burn
    function _burnTokens(address _from, uint256 _amount) internal {
        IMemedToken(memedToken).burnFrom(_from, _amount);
        emit TokensBurned(_amount, factory.getHeat(memedToken));
    }

    /// @dev Remove NFT from user's tracking array
    /// @param _user The user address
    /// @param _tokenId The NFT token ID to remove
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

    /// @dev Override transfer to update ownership tracking
    /// @param to The recipient address
    /// @param tokenId The NFT token ID being transferred
    /// @param auth The authorized address
    /// @return The previous owner address
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = super._update(to, tokenId, auth);

        if (from != address(0) && to != address(0)) {
            warriors[tokenId].owner = to;

            _removeFromUserNFTs(from, tokenId);
            userNFTs[to].push(tokenId);
        }

        return from;
    }

    /// @notice Get all warriors minted before a specific timestamp by a user
    /// @param _user The user address
    /// @param _timestamp The timestamp to check against
    /// @return Array of NFT token IDs minted before the timestamp
    function getWarriorMintedBeforeByUser(
        address _user,
        uint256 _timestamp
    ) external view returns (uint256[] memory) {
        uint256[] memory nfts = userNFTs[_user];
        uint256 count = 0;
        
        for (uint256 i = 0; i < nfts.length; i++) {
            if (warriors[nfts[i]].mintedAt < _timestamp) {
                count++;
            }
        }
        
        uint256[] memory mintedBefore = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < nfts.length; i++) {
            if (warriors[nfts[i]].mintedAt < _timestamp) {
                mintedBefore[index++] = nfts[i];
            }
        }
        return mintedBefore;
    }

    /// @dev Check if an NFT exists
    /// @param _tokenId The NFT token ID to check
    /// @return Whether the NFT exists
    function _exists(uint256 _tokenId) internal view returns (bool) {
        return _tokenId > 0 && _tokenId <= currentTokenId;
    }
}
