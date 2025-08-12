// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MemedToken.sol";
import "./MemedBattle.sol";
import "./MemedWarriorNFT.sol";

// Uniswap V2 interfaces
interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IMemedEngageToEarn {
    function getBattleRewardPool(address token) external view returns (uint256);
    function transferBattleRewards(address token, address winner, uint256 amount) external;
}


contract MemedFactory is Ownable, ReentrancyGuard {
    uint256 constant public REWARD_PER_ENGAGEMENT = 100000;
    uint256 constant public MAX_ENGAGE_USER_REWARD_PERCENTAGE = 2;
    uint256 constant public MAX_ENGAGE_CREATOR_REWARD_PERCENTAGE = 1;
    
    // Bonding curve parameters
    uint256 public constant INITIAL_SUPPLY = 200000000 * 1e18; // 200M token
    uint256 public constant BASE_PRICE = 1e15; // 0.001 native token
    uint256 public constant INITIAL_K = 1e11; // 0.00001
    uint256 public constant K_BOOST_PER_ENGAGEMENT = 1e9; // 0.000001
    uint256 public constant FAIR_LAUNCH_DURATION = 7 days;
    uint256 public constant MIN_FUNDING_GOAL = 20000 * 1e18; // 20,000 native token
    uint256 public constant MAX_WALLET_COMMITMENT = 500 * 1e18; // 500 native token
    uint256 public constant MAX_WALLET_COMMITMENT_NO_SOCIAL = 300 * 1e18; // 300 native token without social proof
    
    // Fund distribution
    uint256 public constant PLATFORM_FEE_PERCENTAGE = 5; // 5% to platform
    uint256 public constant LP_PERCENTAGE = 95; // 95% to LP
    
    // Trading fees
    uint256 public constant SELL_FEE_PERCENTAGE = 15; // 15% fee on sells
    
    MemedBattle public memedBattle;
    IMemedEngageToEarn public memedEngageToEarn;
    IUniswapV2Router02 public uniswapV2Router;
    IUniswapV2Factory public uniswapV2Factory;
    
    struct TokenData {
        address token;
        address warriorNFT;
        address creator;
        string name;
        string ticker;
        string description;
        string image;
        string lensUsername;
        uint256 createdAt;
    }

    enum FairLaunchStatus {
        ACTIVE,
        COMPLETED,
        FAILED
    }

    struct Commitment {
        uint256 amount;
        uint256 tokenAmount;
        bool claimed;
        bool refunded;
        bool hasLensVerification;
    }

    struct FairLaunchData {
        FairLaunchStatus status;
        uint256 fairLaunchStartTime;
        uint256 totalCommitted;
        uint256 totalSold;
        uint256 kValue;
        address uniswapPair;
        mapping(address => Commitment) commitments;
        mapping(address => uint256) balance;
        uint256 lastEngagementBoost;
        uint256 heat;
        uint256 lastRewardAt;
        uint256 createdAt;
    }

    struct HeatUpdate {
        uint256 id;
        uint256 heat;
        bool minusHeat;
    }
    
    // Engagement types for heat calculation
    struct EngagementData {
        uint256 likes;
        uint256 mirrors;
        uint256 quotes;
    }
    
    uint256 public id;
    address[] public tokens;

    mapping(uint256 => FairLaunchData) public fairLaunchData;
    mapping(uint256 => TokenData) public tokenData;
    mapping(address => uint256[]) public tokenIdsByCreator;
    mapping(address => uint256) public tokenIdByAddress;
    mapping(address => uint256) public blockedCreators;
    
    // Events
    event TokenCreated(
        address indexed token,
        address indexed owner,
        string name,
        string ticker,
        string description,
        string image,
        string lensUsername,
        uint256 createdAt
    );
    
    event FairLaunchStarted(
        uint256 indexed id,
        string indexed lensUsername,
        address indexed creator,
        uint256 startTime,
        uint256 endTime
    );
    
    event CommitmentMade(
        uint256 indexed id,
        address indexed user,
        uint256 amount,
        bool hasLensVerification
    );
    
    event FairLaunchCompleted(
        uint256 indexed id,
        address indexed token,
        uint256 totalRaised,
        bool successful
    );
    
    event LiquidityAdded(
        uint256 indexed id,
        address indexed pair,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 liquidity
    );
    
    event CreatorBlocked(
        address indexed creator,
        uint256 blockExpiresAt,
        string reason
    );
    
    event TokenSold(
        uint256 indexed id,
        address indexed seller,
        uint256 tokenAmount,
        uint256 ethReceived,
        uint256 feeAmount
    );
    
    constructor(
        address _memedBattle, 
        address _memedEngageToEarn,
        address _uniswapV2Router
    ) {
        memedBattle = MemedBattle(_memedBattle);
        memedEngageToEarn = IMemedEngageToEarn(_memedEngageToEarn);
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        uniswapV2Factory = IUniswapV2Factory(uniswapV2Router.factory());
    }

    function startFairLaunch(
        address _creator,
        string calldata _lensUsername,
        string calldata _name,
        string calldata _ticker,
        string calldata _description,
        string calldata _image
    ) external onlyOwner {
        require(block.timestamp >= blockedCreators[_creator], "Creator is blocked for 30 days");
        require(!_tokenExists(), "Already exists");
        
        id++;
        TokenData storage token = tokenData[id];
        token.creator = _creator;
        token.name = _name;
        token.ticker = _ticker;
        token.description = _description;
        token.image = _image;
        token.lensUsername = _lensUsername;

        FairLaunchData storage fairLaunch = fairLaunchData[id];
        fairLaunch.status = FairLaunchStatus.ACTIVE;
        fairLaunch.fairLaunchStartTime = block.timestamp;
        fairLaunch.kValue = INITIAL_K;
        fairLaunch.createdAt = block.timestamp;

        tokenIdsByCreator[_creator].push(id);
        emit FairLaunchStarted(id, _lensUsername, _creator, block.timestamp, block.timestamp + FAIR_LAUNCH_DURATION);
    }
    
    function commitToFairLaunch(
        uint256 _id,
        bool _hasLensVerification
    ) external payable nonReentrant {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        require(fairLaunch.status == FairLaunchStatus.ACTIVE, "Fair launch not active");
        require(block.timestamp <= fairLaunch.fairLaunchStartTime + FAIR_LAUNCH_DURATION, "Fair launch ended");
        require(msg.value > 0, "Must send ETH");
        
        uint256 maxCommitment = _hasLensVerification ? MAX_WALLET_COMMITMENT : MAX_WALLET_COMMITMENT_NO_SOCIAL;
        require(fairLaunch.commitments[msg.sender].amount + msg.value <= maxCommitment, "Exceeds wallet limit");
        uint256 tokenAmount = getNativeToTokenAmount(_id, msg.value);
        require(tokenAmount > 0, "Insufficient ETH");
        require(fairLaunch.totalSold + tokenAmount <= INITIAL_SUPPLY, "Exceeds initial supply");
        Commitment storage commitment = fairLaunch.commitments[msg.sender];
        commitment.amount += msg.value;
        commitment.tokenAmount += tokenAmount;
        commitment.hasLensVerification = _hasLensVerification;
        
        fairLaunch.totalSold += tokenAmount;
        fairLaunch.totalCommitted += msg.value;
        fairLaunch.balance[msg.sender] += tokenAmount;
        
        emit CommitmentMade(_id, msg.sender, msg.value, _hasLensVerification);
     
        // Check if we can launch early
        if (fairLaunch.totalCommitted >= MIN_FUNDING_GOAL) {
            _completeFairLaunch(_id);
        }
    }
    
    function _completeFairLaunch(uint256 _id) internal {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        TokenData storage token = tokenData[_id];
        if (fairLaunch.totalCommitted >= MIN_FUNDING_GOAL) {
            // Create the meme token
            MemedToken memedToken = new MemedToken(
                token.name,
                token.ticker,
                token.creator,
                address(memedEngageToEarn),
                address(memedBattle)
            );

            MemedWarriorNFT warriorNFT = new MemedWarriorNFT(address(memedToken));
            token.warriorNFT = address(warriorNFT);
            
            token.token = address(memedToken);
            fairLaunch.status = FairLaunchStatus.COMPLETED;
            tokens.push(address(memedToken));
            
            // Calculate fund distribution: 5% platform, 95% LP
            uint256 platformFee = (fairLaunch.totalCommitted * PLATFORM_FEE_PERCENTAGE) / 100;
            uint256 lpAmount = fairLaunch.totalCommitted - platformFee;
            
            // Send platform fee to owner
            (bool success, ) = payable(owner()).call{value: platformFee}("");
            require(success, "Transfer failed");
            
            // Create Uniswap pair and add liquidity
            _createUniswapLP(_id, address(memedToken), lpAmount);

            tokenIdByAddress[address(memedToken)] = _id;
            
            emit TokenCreated(
                address(memedToken),
                token.creator,
                token.name,
                token.ticker,
                token.description,
                token.image,
                token.lensUsername,
                block.timestamp
            );
            
            emit FairLaunchCompleted(_id, address(memedToken), fairLaunch.totalCommitted, true);
        } else {
            // Failed to reach goal - refund users
            fairLaunch.status = FairLaunchStatus.FAILED;
            uint256 blockExpiry = block.timestamp + 30 days;
            blockedCreators[token.creator] = blockExpiry; // 30-day block
            
            emit CreatorBlocked(token.creator, blockExpiry, "Failed fair launch");
            
            emit FairLaunchCompleted(_id, address(0), fairLaunch.totalCommitted, false);
        }
    }
    
    function _createUniswapLP(uint256 _id, address _token, uint256 _ethAmount) internal {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        
        // Mint LP allocation tokens (300M)
        uint256 lpTokenAmount = MemedToken(_token).UNISWAP_LP_ALLOCATION();
        MemedToken(_token).mintUniswapLP(address(this));
        
        // Create Uniswap pair
        address pair = uniswapV2Factory.createPair(_token, uniswapV2Router.WETH());
        fairLaunch.uniswapPair = pair;
        
        // Approve router to spend tokens
        IERC20(_token).approve(address(uniswapV2Router), lpTokenAmount);
        
        // Add liquidity to Uniswap
        (uint amountToken, uint amountETH, uint liquidity) = uniswapV2Router.addLiquidityETH{value: _ethAmount}(
            _token,
            lpTokenAmount,
            0, // Accept any amount of tokens
            0, // Accept any amount of ETH
            address(0), // LP tokens go to zero address
            block.timestamp + 300 // 5 minute deadline
        );
        
        
        emit LiquidityAdded(_id, pair, amountToken, amountETH, liquidity);
    }

    function swap(
        uint256 _amount,
        address[] calldata _path,
        address _to
    ) external nonReentrant returns (uint256[] memory) {
        IERC20(_path[0]).approve(address(uniswapV2Router), _amount);
        uint256[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            _amount,
            0,
            _path,
            _to,
            block.timestamp + 300
        );
        return amounts;
    }

    function sellTokens(uint256 _id, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be positive");
        require(fairLaunchData[_id].balance[msg.sender] >= _amount, "Insufficient token balance");
        
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        uint256 ethValue = getTokenToNativeToken(_id, _amount);
        uint256 feeAmount = (ethValue * SELL_FEE_PERCENTAGE) / 100;
        uint256 ethToUser = ethValue - feeAmount;
        
        require(address(this).balance >= ethValue, "Insufficient ETH in contract");
        
        fairLaunch.balance[msg.sender] -= _amount;
        fairLaunch.totalSold -= _amount;
        fairLaunch.totalCommitted -= ethValue;

        (bool success, ) = payable(msg.sender).call{value: ethToUser}("");
        require(success, "Transfer failed");
        
        if (feeAmount > 0) {
            (bool success_fee, ) = payable(owner()).call{value: feeAmount}("");
            require(success_fee, "Transfer failed");
        }
        
        emit TokenSold(_id, msg.sender, _amount, ethToUser, feeAmount);
    }

    
    function getTokenToNativeToken(uint256 _id, uint256 _amount) public view returns (uint256 ethValue) {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        // Calculate sell price using bonding curve
        uint256 price = calculateBondingCurvePrice(fairLaunch.totalSold, fairLaunch.kValue);
        ethValue = (_amount * price) / 1e18;
        return ethValue;
    }
    
    function getNativeToTokenAmount(uint256 _id, uint256 _ethAmount) public view returns (uint256 tokenAmount) {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        // Calculate buy price using bonding curve
        uint256 price = calculateBondingCurvePrice(fairLaunch.totalSold, fairLaunch.kValue);
        require(price > 0, "Price cannot be zero");
        tokenAmount = (_ethAmount * 1e18) / price;
        return tokenAmount;
    }
    
    function claim(uint256 _id) external nonReentrant {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        require(fairLaunch.status == FairLaunchStatus.COMPLETED, "Fair launch not completed");
        Commitment storage commitment = fairLaunch.commitments[msg.sender];
        require(commitment.amount > 0, "No commitment");
        require(!commitment.claimed, "Already claimed");
        MemedToken(tokenData[_id].token).claim(msg.sender, commitment.tokenAmount);
        commitment.claimed = true;
    }
    
    function refund(uint256 _id) external nonReentrant {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        require(fairLaunch.status == FairLaunchStatus.FAILED, "Fair launch not failed");
        Commitment storage commitment = fairLaunch.commitments[msg.sender];
        require(commitment.amount > 0, "No commitment");
        require(!commitment.refunded, "Already refunded");
        (bool success, ) = payable(msg.sender).call{value: commitment.amount}("");
        require(success, "Transfer failed");
        commitment.refunded = true;
    }

    function calculateBondingCurvePrice(uint256 _supply, uint256 _kValue) public pure returns (uint256) {
        // Price = Base Price × (1 + k × Supply)²
        uint256 factor = 1e18 + (_kValue * _supply) / 1e18;
        uint256 priceMultiplier = (factor * factor) / 1e18;
        return (BASE_PRICE * priceMultiplier) / 1e18;
    }
    
    function updateEngagement(
        uint256 _id,
        EngagementData calldata _engagement
    ) external onlyOwner {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        require(fairLaunch.status == FairLaunchStatus.COMPLETED, "Fair launch not completed");
        
        // Calculate heat using proper formula: (Likes × 1) + (Mirrors × 3) + (Quotes × 5)
        uint256 heatIncrease = _engagement.likes + (_engagement.mirrors * 3) + (_engagement.quotes * 5);
        
        // Update k-value for bonding curve (boost for 24h)
        if (block.timestamp < fairLaunch.lastEngagementBoost + 1 days) {
            fairLaunch.kValue += K_BOOST_PER_ENGAGEMENT;
        }
        fairLaunch.lastEngagementBoost = block.timestamp;
        
        // Create memory array for heat update
        HeatUpdate[] memory heatUpdate = new HeatUpdate[](1);
        heatUpdate[0] = HeatUpdate({
            id: _id,
            heat: heatIncrease,
            minusHeat: false
        });
        _updateHeatInternal(heatUpdate);
    }
    
    function _updateHeatInternal(HeatUpdate[] memory _heatUpdates) internal {
        for(uint i = 0; i < _heatUpdates.length; i++) {
            TokenData storage token = tokenData[_heatUpdates[i].id];
            FairLaunchData storage fairLaunch = fairLaunchData[_heatUpdates[i].id];
            if(_heatUpdates[i].minusHeat) {
                fairLaunch.heat -= _heatUpdates[i].heat;
            } else {
                fairLaunch.heat += _heatUpdates[i].heat;
            }
            
            if (fairLaunch.status == FairLaunchStatus.COMPLETED && (fairLaunch.heat - fairLaunch.lastRewardAt) >= REWARD_PER_ENGAGEMENT && memedEngageToEarn.isRewardable(token.token)) {
                memedEngageToEarn.reward(token.token);
                fairLaunch.lastRewardAt = fairLaunch.heat;
            }
        }
    }

    function updateHeat(HeatUpdate[] calldata _heatUpdates) public {
        require(
            msg.sender == address(memedBattle) || 
            msg.sender == owner(), 
            "unauthorized"
        );
        
        // Convert calldata to memory for internal processing
        HeatUpdate[] memory heatUpdatesMemory = new HeatUpdate[](_heatUpdates.length);
        for(uint i = 0; i < _heatUpdates.length; i++) {
            heatUpdatesMemory[i] = _heatUpdates[i];
        }
        
        _updateHeatInternal(heatUpdatesMemory);
    }

    function getByToken(address _token) public view returns (TokenData memory) {
        return tokenData[tokenIdByAddress[_token]];
    }

    function getWarriorNFT(address _token) external view returns (address) {
        return tokenData[tokenIdByAddress[_token]].warriorNFT;
    }

    function getHeat(address _token) external view returns (uint256) {
        return fairLaunchData[tokenIdByAddress[_token]].heat;
    }

    function getTokens() external view returns (TokenData[] memory) {
        TokenData[] memory result = new TokenData[](tokens.length);
        for(uint i = 0; i < tokens.length; i++) {
            result[i] = tokenData[tokenIdByAddress[tokens[i]]];
        }
        return result;
    }

    function getFairLaunchActive(address _token) public view returns (bool) {
        uint256 tokenId = tokenIdByAddress[_token];
        if(tokenId == 0) {
            return false;
        }
        FairLaunchData storage fairLaunch = fairLaunchData[tokenId];
        return fairLaunch.status == FairLaunchStatus.ACTIVE;
    }

    function _tokenExists() internal view returns (bool) {
        uint256[] memory tokenIds = tokenIdsByCreator[msg.sender];
        for(uint i = 0; i < tokenIds.length; i++) {
            if(fairLaunchData[tokenIds[i]].status == FairLaunchStatus.COMPLETED) {
                return true;
            }
        }
        return false;
    }

    
    function getUserCommitment(uint256 _id, address _user) external view returns (Commitment memory) {
        return fairLaunchData[_id].commitments[_user];
    }
    
    function isCreatorBlocked(address _creator) external view returns (bool blocked, uint256 blockExpiresAt) {
        blockExpiresAt = blockedCreators[_creator];
        blocked = block.timestamp < blockExpiresAt;
        return (blocked, blockExpiresAt);
    }
    
    function withdrawETH(uint256 _amount) external onlyOwner {
        (bool success, ) = payable(owner()).call{value: _amount}("");
        require(success, "Transfer failed");
    }
    // Receive ETH
    receive() external payable {}
}