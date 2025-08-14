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
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
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
    function isRewardable(address _token) external view returns (bool);
    function registerEngagementReward(address _token) external;
    function getBattleRewardPool(address _token) external view returns (uint256);
    function transferBattleRewards(address _loser, address _winner, uint256 _amount) external returns (uint256);
    function claimBattleRewards(address _token, address _winner, uint256 _amount) external;
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
    uint256 public minFundingGoal = 20000 * 1e18; // 20,000 native token
    uint256 public maxWalletCommitment = 500 * 1e18; // 500 native token
    uint256 public maxWalletCommitmentNoSocial = 300 * 1e18; // 300 native token without social proof
    
    // Platform fee for trading fees, minting fee, and LP fee
    uint256 public platformFeePercentage = 10; // 1% to platform (10/1000)
    uint256 public feeDenominator = 1000; // For 1% fee calculation
    
    // Engagement rewards
    uint256 public constant ENGAGEMENT_REWARDS_PER_NEW_HEAT = 50000; // For every 50,000 heat, 1 engagement reward is given
    
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
        uint256 lastRewardAt;
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
        uint256 createdAt;
    }

    struct HeatUpdate {
        uint256 id;
        uint256 heat;
    }

    uint256 public id;
    address[] public tokens;

    mapping(uint256 => FairLaunchData) public fairLaunchData;
    mapping(uint256 => TokenData) public tokenData;
    mapping(address => uint256[]) public tokenIdsByCreator;
    mapping(address => uint256) public tokenIdByAddress;
    mapping(address => bool) public hasLensVerification;
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
        uint256 ethReceived
    );

    event HeatUpdated(
        uint256 indexed id,
        uint256 heat,
        uint256 timestamp
    );
    
    event PlatformFeeCollected(
        uint256 indexed id,
        address indexed user,
        uint256 feeAmount,
        string transactionType
    );
    
    event PlatformFeeSet(
        uint256 platformFeePercentage,
        uint256 feeDenominator
    );
    
    event FairLaunchParamsSet(
        uint256 minFundingGoal,
        uint256 maxWalletCommitment,
        uint256 maxWalletCommitmentNoSocial
    );

    event HasLensVerificationSet(
        address indexed user,
        bool hasLensVerification
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
        uint256 _id
    ) external payable nonReentrant {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        require(fairLaunch.status == FairLaunchStatus.ACTIVE, "Fair launch not active");
        require(block.timestamp <= fairLaunch.fairLaunchStartTime + FAIR_LAUNCH_DURATION, "Fair launch ended");
        require(msg.value > 0, "Must send ETH");
        
        // Calculate platform fee (1%)
        uint256 platformFee = (msg.value * platformFeePercentage) / feeDenominator;
        uint256 ethAfterFee = msg.value - platformFee;
        
        uint256 maxCommitment = hasLensVerification[msg.sender] ? maxWalletCommitment : maxWalletCommitmentNoSocial;
        require(fairLaunch.commitments[msg.sender].amount + msg.value <= maxCommitment, "Exceeds wallet limit");
        uint256 tokenAmount = getNativeToTokenAmount(_id, ethAfterFee);
        require(tokenAmount > 0, "Insufficient ETH");
        require(fairLaunch.totalSold + tokenAmount <= INITIAL_SUPPLY, "Exceeds initial supply");
        
        // Send platform fee to owner
        if (platformFee > 0) {
            (bool feeSuccess, ) = payable(owner()).call{value: platformFee}("");
            require(feeSuccess, "Fee transfer failed");
            emit PlatformFeeCollected(_id, msg.sender, platformFee, "buy");
        }
        
        Commitment storage commitment = fairLaunch.commitments[msg.sender];
        commitment.amount += ethAfterFee; // Store amount after fee
        commitment.tokenAmount += tokenAmount;
        commitment.hasLensVerification = hasLensVerification[msg.sender];
        
        fairLaunch.totalSold += tokenAmount;
        fairLaunch.totalCommitted += ethAfterFee; // Track committed amount after fee
        fairLaunch.balance[msg.sender] += tokenAmount;
        
        emit CommitmentMade(_id, msg.sender, msg.value, hasLensVerification[msg.sender]);
     
        // Check if we can launch early
        if (fairLaunch.totalCommitted >= minFundingGoal) {
            _completeFairLaunch(_id);
        }
    }

    function setHasLensVerification(address _user, bool _hasLensVerification) external onlyOwner {
        hasLensVerification[_user] = _hasLensVerification;
        emit HasLensVerificationSet(_user, _hasLensVerification);
    }
    
    function _completeFairLaunch(uint256 _id) internal {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        TokenData storage token = tokenData[_id];
        if (fairLaunch.totalCommitted >= minFundingGoal) {
            // Create the meme token
            MemedToken memedToken = new MemedToken(
                token.name,
                token.ticker,
                token.creator,
                address(memedEngageToEarn)
            );

            MemedWarriorNFT warriorNFT = new MemedWarriorNFT(address(memedToken), address(memedBattle));
            token.warriorNFT = address(warriorNFT);
            
            token.token = address(memedToken);
            fairLaunch.status = FairLaunchStatus.COMPLETED;
            tokens.push(address(memedToken));
            
            // Calculate fund distribution: 1% platform, 99% LP
            uint256 platformFee = (fairLaunch.totalCommitted * platformFeePercentage) / feeDenominator;
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

    function swapExactForNativeToken(
        uint256 _amount,
        address _token,
        address _to
    ) external returns (uint[] memory amounts) {
        IERC20(_token).approve(address(uniswapV2Router), _amount);
        address[] memory path = new address[](2);
        path[0] = _token;
        path[1] = uniswapV2Router.WETH();
        return uniswapV2Router.swapExactTokensForETH(
            _amount,
            0,
            path,
            _to,
            block.timestamp + 300
        );
    }

    function sellTokens(uint256 _id, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be positive");
        require(fairLaunchData[_id].balance[msg.sender] >= _amount, "Insufficient token balance");
        
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        uint256 ethValue = getTokenToNativeToken(_id, _amount);
        
        // Calculate platform fee (1%)
        uint256 platformFee = (ethValue * platformFeePercentage) / feeDenominator;
        uint256 ethToUser = ethValue - platformFee;
        
        require(address(this).balance >= ethValue, "Insufficient ETH in contract");
        
        // Send platform fee to owner
        if (platformFee > 0) {
            (bool feeSuccess, ) = payable(owner()).call{value: platformFee}("");
            require(feeSuccess, "Fee transfer failed");
            emit PlatformFeeCollected(_id, msg.sender, platformFee, "sell");
        }
        
        fairLaunch.balance[msg.sender] -= _amount;
        fairLaunch.totalSold -= _amount;
        fairLaunch.totalCommitted -= ethValue;

        (bool success, ) = payable(msg.sender).call{value: ethToUser}("");
        require(success, "Transfer failed");
        
        emit TokenSold(_id, msg.sender, _amount, ethToUser);
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
    
    function _updateHeatInternal(HeatUpdate[] memory _heatUpdates) internal {
        for(uint i = 0; i < _heatUpdates.length; i++) {
            TokenData storage token = tokenData[_heatUpdates[i].id];
            FairLaunchData storage fairLaunch = fairLaunchData[_heatUpdates[i].id];
            fairLaunch.heat += _heatUpdates[i].heat;
            
            if (fairLaunch.status == FairLaunchStatus.COMPLETED && (fairLaunch.heat - token.lastRewardAt) >= ENGAGEMENT_REWARDS_PER_NEW_HEAT && memedEngageToEarn.isRewardable(token.token)) {
                memedEngageToEarn.registerEngagementReward(token.token);
                token.lastRewardAt = fairLaunch.heat;
            }
            emit HeatUpdated(_heatUpdates[i].id, fairLaunch.heat, block.timestamp);
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
    
    function setPlatformFee(uint256 _platformFeePercentage, uint256 _feeDenominator) external onlyOwner {
        platformFeePercentage = _platformFeePercentage;
        feeDenominator = _feeDenominator;
        emit PlatformFeeSet(_platformFeePercentage, _feeDenominator);
    }

    function setFairLaunchParams(uint256 _minFundingGoal, uint256 _maxWalletCommitment, uint256 _maxWalletCommitmentNoSocial) external onlyOwner {
        minFundingGoal = _minFundingGoal;
        maxWalletCommitment = _maxWalletCommitment;
        maxWalletCommitmentNoSocial = _maxWalletCommitmentNoSocial;
        emit FairLaunchParamsSet(_minFundingGoal, _maxWalletCommitment, _maxWalletCommitmentNoSocial);
    }
    
    // Receive ETH
    receive() external payable {}
}