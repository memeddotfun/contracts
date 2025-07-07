// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MemedToken.sol";
import "./MemedStaking.sol";
import "./MemedBattle.sol";
import "./MemedEngageToEarn.sol";

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
}

contract MemedFactory is Ownable, ReentrancyGuard {
    uint256 constant public REWARD_PER_ENGAGEMENT = 100000;
    uint256 constant public MAX_ENGAGE_USER_REWARD_PERCENTAGE = 2;
    uint256 constant public MAX_ENGAGE_CREATOR_REWARD_PERCENTAGE = 1;
    
    // Bonding curve parameters
    uint256 public constant BASE_PRICE = 1e15; // 0.001 ETH
    uint256 public constant INITIAL_K = 1e11; // 0.00001
    uint256 public constant K_BOOST_PER_ENGAGEMENT = 1e9; // 0.000001
    uint256 public constant FAIR_LAUNCH_DURATION = 7 days;
    uint256 public constant MIN_FUNDING_GOAL = 20 ether; // 20 ETH
    uint256 public constant MAX_WALLET_COMMITMENT = 0.5 ether; // 0.5 ETH
    uint256 public constant MAX_WALLET_COMMITMENT_NO_SOCIAL = 0.3 ether; // 0.3 ETH without social proof
    
    // Fund distribution
    uint256 public constant PLATFORM_FEE_PERCENTAGE = 5; // 5% to platform
    uint256 public constant LP_PERCENTAGE = 95; // 95% to LP
    
    // Trading fees
    uint256 public constant SELL_FEE_PERCENTAGE = 15; // 15% fee on sells
    
    // Battle requirements
    uint256 public constant BATTLE_STAKE_REQUIREMENT = 10_000_000 * 1e18; // 10M tokens
    uint256 public constant BATTLE_BURN_PERCENTAGE = 15; // 15%
    uint256 public constant BATTLE_PLATFORM_FEE_PERCENTAGE = 5; // 5%
    
    MemedStaking public memedStaking;
    MemedBattle public memedBattle;
    MemedEngageToEarn public memedEngageToEarn;
    IUniswapV2Router02 public uniswapV2Router;
    IUniswapV2Factory public uniswapV2Factory;
    
    struct TokenData {
        address token;
        address creator;
        string name;
        string ticker;
        string description;
        string image;
        string lensUsername;
        uint256 heat;
        uint256 lastRewardAt;
        uint256 createdAt;
        // Fair launch data
        bool fairLaunchActive;
        uint256 fairLaunchStartTime;
        uint256 totalCommitted;
        uint256 kValue;
        uint256 lastEngagementBoost;
        address uniswapPair;
        mapping(address => uint256) commitments;
        mapping(address => bool) hasLensVerification;
    }
    
    // Return struct without mappings for external functions
    struct TokenDataView {
        address token;
        address creator;
        string name;
        string ticker;
        string description;
        string image;
        string lensUsername;
        uint256 heat;
        uint256 lastRewardAt;
        uint256 createdAt;
        bool fairLaunchActive;
        uint256 fairLaunchStartTime;
        uint256 totalCommitted;
        uint256 kValue;
        uint256 lastEngagementBoost;
        address uniswapPair;
    }

    struct HeatUpdate {
        address token;
        uint256 heat;
        bool minusHeat;
    }
    
    // Engagement types for heat calculation
    struct EngagementData {
        uint256 likes;
        uint256 mirrors;
        uint256 quotes;
    }

    mapping(string => TokenData) public tokenData;
    string[] public tokens;
    mapping(address => uint256) public blockedCreators; // timestamp when block expires

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
        string indexed lensUsername,
        address indexed creator,
        uint256 startTime,
        uint256 endTime
    );
    
    event CommitmentMade(
        string indexed lensUsername,
        address indexed user,
        uint256 amount,
        bool hasLensVerification
    );
    
    event FairLaunchCompleted(
        string indexed lensUsername,
        address indexed token,
        uint256 totalRaised,
        bool successful
    );
    
    event LiquidityAdded(
        address indexed token,
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
        address indexed token,
        address indexed seller,
        uint256 tokenAmount,
        uint256 ethReceived,
        uint256 feeAmount
    );

    event Followed(
        address indexed follower,
        address indexed following,
        uint256 timestamp
    );
    event Unfollowed(
        address indexed follower,
        address indexed following,
        uint256 timestamp
    );

    constructor(
        address _memedStaking, 
        address _memedBattle, 
        address _memedEngageToEarn,
        address _uniswapV2Router
    ) {
        memedStaking = MemedStaking(_memedStaking);
        memedBattle = MemedBattle(_memedBattle);
        memedEngageToEarn = MemedEngageToEarn(_memedEngageToEarn);
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        uniswapV2Factory = IUniswapV2Factory(uniswapV2Router.factory());
    }

    function startFairLaunch(
        string calldata _lensUsername,
        string calldata _name,
        string calldata _ticker,
        string calldata _description,
        string calldata _image
    ) external {
        require(block.timestamp >= blockedCreators[msg.sender], "Creator is blocked for 30 days");
        require(tokenData[_lensUsername].token == address(0), "Already exists");
        
        TokenData storage token = tokenData[_lensUsername];
        token.creator = msg.sender;
        token.name = _name;
        token.ticker = _ticker;
        token.description = _description;
        token.image = _image;
        token.lensUsername = _lensUsername;
        token.fairLaunchActive = true;
        token.fairLaunchStartTime = block.timestamp;
        token.kValue = INITIAL_K;
        token.createdAt = block.timestamp;
        
        tokens.push(_lensUsername);
        
        emit FairLaunchStarted(_lensUsername, msg.sender, block.timestamp, block.timestamp + FAIR_LAUNCH_DURATION);
    }
    
    function commitToFairLaunch(
        string calldata _lensUsername,
        bool _hasLensVerification
    ) external payable nonReentrant {
        TokenData storage token = tokenData[_lensUsername];
        require(token.fairLaunchActive, "Fair launch not active");
        require(block.timestamp <= token.fairLaunchStartTime + FAIR_LAUNCH_DURATION, "Fair launch ended");
        require(msg.value > 0, "Must send ETH");
        
        uint256 maxCommitment = _hasLensVerification ? MAX_WALLET_COMMITMENT : MAX_WALLET_COMMITMENT_NO_SOCIAL;
        require(token.commitments[msg.sender] + msg.value <= maxCommitment, "Exceeds wallet limit");
        
        token.commitments[msg.sender] += msg.value;
        token.totalCommitted += msg.value;
        token.hasLensVerification[msg.sender] = _hasLensVerification;
        
        emit CommitmentMade(_lensUsername, msg.sender, msg.value, _hasLensVerification);
        
        // Check if we can launch early
        if (token.totalCommitted >= MIN_FUNDING_GOAL) {
            _completeFairLaunch(_lensUsername);
        }
    }
    
    function completeFairLaunch(string calldata _lensUsername) external {
        TokenData storage token = tokenData[_lensUsername];
        require(token.fairLaunchActive, "Fair launch not active");
        require(
            block.timestamp > token.fairLaunchStartTime + FAIR_LAUNCH_DURATION ||
            msg.sender == owner(),
            "Fair launch not ended"
        );
        
        _completeFairLaunch(_lensUsername);
    }
    
    function _completeFairLaunch(string memory _lensUsername) internal {
        TokenData storage token = tokenData[_lensUsername];
        
        if (token.totalCommitted >= MIN_FUNDING_GOAL) {
            // Create the meme token
            MemedToken memedToken = new MemedToken(
                token.name,
                token.ticker,
                token.creator,
                address(memedStaking),
                address(memedEngageToEarn)
            );
            
            token.token = address(memedToken);
            token.fairLaunchActive = false;
            
            // Distribute tokens based on bonding curve
            _distributeFairLaunchTokens(_lensUsername, address(memedToken));
            
            // Complete fair launch and enable LP minting
            memedToken.completeFairLaunch();
            
            // Calculate fund distribution: 5% platform, 95% LP
            uint256 platformFee = (token.totalCommitted * PLATFORM_FEE_PERCENTAGE) / 100;
            uint256 lpAmount = token.totalCommitted - platformFee;
            
            // Send platform fee to owner
            payable(owner()).transfer(platformFee);
            
            // Create Uniswap pair and add liquidity
            _createUniswapLP(_lensUsername, address(memedToken), lpAmount);
            
            memedEngageToEarn.reward(address(memedToken), token.creator);
            
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
            
            emit FairLaunchCompleted(_lensUsername, address(memedToken), token.totalCommitted, true);
        } else {
            // Failed to reach goal - refund users
            token.fairLaunchActive = false;
            uint256 blockExpiry = block.timestamp + 30 days;
            blockedCreators[token.creator] = blockExpiry; // 30-day block
            
            emit CreatorBlocked(token.creator, blockExpiry, "Failed fair launch");
            emit FairLaunchCompleted(_lensUsername, address(0), token.totalCommitted, false);
        }
    }
    
    function _createUniswapLP(string memory _lensUsername, address _token, uint256 _ethAmount) internal {
        TokenData storage token = tokenData[_lensUsername];
        
        // Mint LP allocation tokens (300M)
        uint256 lpTokenAmount = MemedToken(_token).UNISWAP_LP_ALLOCATION();
        MemedToken(_token).mintUniswapLP(address(this));
        
        // Create Uniswap pair
        address pair = uniswapV2Factory.createPair(_token, uniswapV2Router.WETH());
        token.uniswapPair = pair;
        
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
        
        emit LiquidityAdded(_token, pair, amountToken, amountETH, liquidity);
    }
    
    function sellTokens(address _token, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be positive");
        require(IERC20(_token).balanceOf(msg.sender) >= _amount, "Insufficient token balance");
        
        string memory lensUsername = getByToken(_token);
        TokenData storage token = tokenData[lensUsername];
        require(token.token != address(0), "Token not found");
        require(!token.fairLaunchActive, "Fair launch still active");
        
        // Calculate sell price using bonding curve
        uint256 currentSupply = IERC20(_token).totalSupply();
        uint256 sellPrice = calculateBondingCurvePrice(currentSupply, token.kValue);
        uint256 ethValue = (_amount * sellPrice) / 1e18;
        
        // Apply 15% sell fee
        uint256 feeAmount = (ethValue * SELL_FEE_PERCENTAGE) / 100;
        uint256 ethToUser = ethValue - feeAmount;
        
        require(address(this).balance >= ethValue, "Insufficient ETH in contract");
        
        // Transfer tokens from user to contract (effectively burning them from circulation)
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        
        // Send ETH to user (minus fee)
        payable(msg.sender).transfer(ethToUser);
        
        // Send fee to platform owner
        if (feeAmount > 0) {
            payable(owner()).transfer(feeAmount);
        }
        
        emit TokenSold(_token, msg.sender, _amount, ethToUser, feeAmount);
    }
    
    function getSellQuote(address _token, uint256 _amount) external view returns (uint256 ethValue, uint256 feeAmount, uint256 ethToUser) {
        string memory lensUsername = getByToken(_token);
        TokenData storage token = tokenData[lensUsername];
        require(token.token != address(0), "Token not found");
        
        // Calculate sell price using bonding curve
        uint256 currentSupply = IERC20(_token).totalSupply();
        uint256 sellPrice = calculateBondingCurvePrice(currentSupply, token.kValue);
        ethValue = (_amount * sellPrice) / 1e18;
        
        // Apply 15% sell fee
        feeAmount = (ethValue * SELL_FEE_PERCENTAGE) / 100;
        ethToUser = ethValue - feeAmount;
        
        return (ethValue, feeAmount, ethToUser);
    }
    
    function _distributeFairLaunchTokens(string memory _lensUsername, address _token) internal {
        TokenData storage token = tokenData[_lensUsername];
        
        // Calculate total tokens to distribute (200M allocation)
        uint256 totalAllocation = MemedToken(_token).UNISWAP_LP_ALLOCATION();
        
        // Simple pro-rata distribution for now
        // In production, this would use the bonding curve calculation
        for (uint i = 0; i < tokens.length; i++) {
            if (keccak256(bytes(tokens[i])) == keccak256(bytes(_lensUsername))) {
                // This is a simplified version - would need to iterate through all commitments
                // For now, we'll mint the allocation to this contract for later distribution
                MemedToken(_token).mintFairLaunchTokens(address(this), totalAllocation);
                break;
            }
        }
    }
    
    function calculateBondingCurvePrice(uint256 _supply, uint256 _kValue) public pure returns (uint256) {
        // Price = Base Price × (1 + k × Supply)²
        uint256 factor = 1e18 + (_kValue * _supply) / 1e18;
        uint256 priceMultiplier = (factor * factor) / 1e18;
        return (BASE_PRICE * priceMultiplier) / 1e18;
    }
    
    function updateEngagement(
        string calldata _lensUsername,
        EngagementData calldata _engagement
    ) external onlyOwner {
        TokenData storage token = tokenData[_lensUsername];
        require(token.token != address(0), "Token not created");
        
        // Calculate heat using proper formula: (Likes × 1) + (Mirrors × 3) + (Quotes × 5)
        uint256 heatIncrease = _engagement.likes + (_engagement.mirrors * 3) + (_engagement.quotes * 5);
        
        // Update k-value for bonding curve (boost for 24h)
        if (block.timestamp < token.lastEngagementBoost + 1 days) {
            token.kValue += K_BOOST_PER_ENGAGEMENT;
        }
        token.lastEngagementBoost = block.timestamp;
        
        // Create memory array for heat update
        HeatUpdate[] memory heatUpdate = new HeatUpdate[](1);
        heatUpdate[0] = HeatUpdate({
            token: token.token,
            heat: heatIncrease,
            minusHeat: false
        });
        _updateHeatInternal(heatUpdate);
    }
    
    function _updateHeatInternal(HeatUpdate[] memory _heatUpdates) internal {
        for(uint i = 0; i < _heatUpdates.length; i++) {
            address tokenAddress = _heatUpdates[i].token;
            uint256 heat = _heatUpdates[i].heat;
            bool minusHeat = _heatUpdates[i].minusHeat;
            
            string memory lensUsername = getByToken(tokenAddress);
            address creator = tokenData[lensUsername].creator;
            require(tokenData[lensUsername].token != address(0), "not minted");
            
            if(minusHeat) {
                tokenData[lensUsername].heat -= heat;
            } else {
                tokenData[lensUsername].heat += heat;
            }
            
            MemedBattle.Battle[] memory battles = memedBattle.getUserBattles(tokenAddress);
            for(uint j = 0; j < battles.length; j++) {
                if(battles[j].memeA == address(0) || battles[j].memeB == address(0)) {
                    continue;
                }
                address opponent = battles[j].memeA == tokenAddress ? battles[j].memeB : battles[j].memeA;
                if(block.timestamp > battles[j].endTime && !battles[j].resolved) {
                    address winner = tokenData[getByToken(opponent)].heat > tokenData[lensUsername].heat ? opponent : tokenAddress;
                    memedBattle.resolveBattle(battles[j].battleId, winner);
                    if(memedStaking.isRewardable(tokenAddress)) {
                        memedStaking.reward(tokenAddress, creator);
                    }
                }
            }
            
            if ((tokenData[lensUsername].heat - tokenData[lensUsername].lastRewardAt) >= REWARD_PER_ENGAGEMENT && memedEngageToEarn.isRewardable(tokenAddress)) {
                memedEngageToEarn.reward(tokenAddress, creator);
                tokenData[lensUsername].lastRewardAt = tokenData[lensUsername].heat;
                if(memedStaking.isRewardable(tokenAddress)) {
                    memedStaking.reward(tokenAddress, creator);
                }
            }
        }
    }

    function updateHeat(HeatUpdate[] calldata _heatUpdates) public {
        require(
            msg.sender == address(memedStaking) || 
            msg.sender == address(memedBattle) || 
            msg.sender == owner(), 
            "unauthorized"
        );
        
        // Convert calldata to memory for internal processing
        HeatUpdate[] memory heatUpdatesMemory = new HeatUpdate[](_heatUpdates.length);
        for(uint i = 0; i < _heatUpdates.length; i++) {
            heatUpdatesMemory[i] = _heatUpdates[i];
            // Additional check for staking contract minus heat permission
            require(!_heatUpdates[i].minusHeat || (msg.sender == address(memedStaking)), "Only staking can minus heat");
        }
        
        _updateHeatInternal(heatUpdatesMemory);
    }

    function getByToken(address _token) internal view returns (string memory) {
        string memory lensUsername;
        for (uint i = 0; i < tokens.length; i++) {
            if (tokenData[tokens[i]].token == _token) {
                lensUsername = tokens[i];
                break;
            }
        }
        return lensUsername;
    }

    function getByAddress(address _token, address _creator) public view returns (address[2] memory) {
        address token;
        address creator;
        if(_token == address(0)) {
            for (uint i = 0; i < tokens.length; i++) {
                if (tokenData[tokens[i]].creator == _creator) {
                    token = tokenData[tokens[i]].token;
                    creator = _creator;
                }
            }
        } else {
            for (uint i = 0; i < tokens.length; i++) {
                if (tokenData[tokens[i]].token == _token) {
                    token = _token;
                    creator = tokenData[tokens[i]].creator;
                }
            }
        }
        return [token, creator];
    }

    function getTokens(address _token) external view returns (TokenDataView[] memory) {
        uint length = address(0) == _token ? tokens.length : 1;
        TokenDataView[] memory result = new TokenDataView[](length);
        if(address(0) == _token) {
            for (uint i = 0; i < length; i++) {
                result[i] = _getTokenDataView(tokens[i]);
            }
        } else {
            result[0] = _getTokenDataView(getByToken(_token));
        }
        return result;
    }
    
    function _getTokenDataView(string memory _lensUsername) internal view returns (TokenDataView memory) {
        TokenData storage original = tokenData[_lensUsername];
        return TokenDataView({
            token: original.token,
            creator: original.creator,
            name: original.name,
            ticker: original.ticker,
            description: original.description,
            image: original.image,
            lensUsername: original.lensUsername,
            heat: original.heat,
            lastRewardAt: original.lastRewardAt,
            createdAt: original.createdAt,
            fairLaunchActive: original.fairLaunchActive,
            fairLaunchStartTime: original.fairLaunchStartTime,
            totalCommitted: original.totalCommitted,
            kValue: original.kValue,
            lastEngagementBoost: original.lastEngagementBoost,
            uniswapPair: original.uniswapPair
        });
    }
    
    function getUserCommitment(string calldata _lensUsername, address _user) external view returns (uint256) {
        return tokenData[_lensUsername].commitments[_user];
    }
    
    function getUniswapPair(string calldata _lensUsername) external view returns (address) {
        return tokenData[_lensUsername].uniswapPair;
    }
    
    function isCreatorBlocked(address _creator) external view returns (bool blocked, uint256 blockExpiresAt) {
        blockExpiresAt = blockedCreators[_creator];
        blocked = block.timestamp < blockExpiresAt;
        return (blocked, blockExpiresAt);
    }
    
    function getContractETHBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    function withdrawETH(uint256 _amount) external onlyOwner {
        payable(owner()).transfer(_amount);
    }
    
    function getUserTokenAllowance(address _token, address _user) external view returns (uint256) {
        return IERC20(_token).allowance(_user, address(this));
    }
    
    function refundFailedLaunch(string calldata _lensUsername) external nonReentrant {
        TokenData storage token = tokenData[_lensUsername];
        require(!token.fairLaunchActive, "Fair launch still active");
        require(token.token == address(0), "Fair launch succeeded");
        
        uint256 commitment = token.commitments[msg.sender];
        require(commitment > 0, "No commitment to refund");
        
        token.commitments[msg.sender] = 0;
        
        // Refund 90% (10% penalty for failed launch)
        uint256 refundAmount = (commitment * 90) / 100;
        payable(msg.sender).transfer(refundAmount);
    }
    
    // Receive ETH
    receive() external payable {}
}
