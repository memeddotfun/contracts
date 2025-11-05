// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IMemedBattle.sol";
import "../interfaces/IUniswapV3.sol";
import "../interfaces/IMemedToken.sol";
import "../interfaces/IMemedTokenSale.sol";
import "../interfaces/IMemedEngageToEarn.sol";
import "../structs/FactoryStructs.sol";

contract MemedFactory_test is Ownable, ReentrancyGuard {
    address public constant MEMED_TEST_ETH =
        0xc190e6F26cE14e40D30251fDe25927A73a5D58b6;
    uint256 public constant REWARD_PER_ENGAGEMENT = 100000;
    uint256 public constant MAX_ENGAGE_USER_REWARD_PERCENTAGE = 2;
    uint256 public constant MAX_ENGAGE_CREATOR_REWARD_PERCENTAGE = 1;

    // Battle rewards
    uint256 public INITIAL_REWARDS_PER_HEAT = 100000; // 100,000 of heat will be required to unlock the battle rewards
    uint256 public BATTLE_REWARDS_PERCENTAGE = 20; // 20% of heat will be inceased or decreased based on the battle result

    // Engagement rewards
    uint256 public constant ENGAGEMENT_REWARDS_PER_NEW_HEAT = 50000; // For every 50,000 heat, 1 engagement reward is given

    IMemedTokenSale public memedTokenSale;
    IMemedBattle public memedBattle;
    IMemedEngageToEarn public memedEngageToEarn;

    mapping(uint256 => TokenData) public tokenData;
    mapping(uint256 => TokenRewardData) public tokenRewardData;
    mapping(address => uint256) public lpTokenIds; // Store LP NFT token IDs for fee collection
    address[] public tokens;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public uniswapV3Factory;
    ISwapRouter public swapRouter;
    uint24 public constant POOL_FEE = 3000; // 0.3%

    // Events
    event TokenCreated(
        uint256 indexed id,
        address indexed token,
        address indexed owner,
        string name,
        string ticker,
        string description,
        string image,
        bool isClaimedByCreator,
        uint256 createdAt
    );

    event TokenCompletedFairLaunch(
        uint256 indexed id,
        address indexed token,
        address indexed warriorNFT
    );

    event HeatUpdated(address indexed token, uint256 heat, uint256 timestamp);

    event BattleUpdated(
        address indexed winner,
        address indexed loser,
        uint256 creatorIncentivesUnlocksAtWinner,
        uint256 creatorIncentivesUnlocksAtLoser
    );

    constructor(
        address _memedTokenSale,
        address _memedBattle,
        address _memedEngageToEarn,
        address _positionManager,
        address _swapRouter
    ) Ownable(msg.sender) {
        memedTokenSale = IMemedTokenSale(_memedTokenSale);
        memedBattle = IMemedBattle(_memedBattle);
        memedEngageToEarn = IMemedEngageToEarn(_memedEngageToEarn);
        positionManager = INonfungiblePositionManager(_positionManager);
        swapRouter = ISwapRouter(_swapRouter);
        uniswapV3Factory = IUniswapV3Factory(positionManager.factory());
    }

    function startFairLaunch(
        address _creator,
        string calldata _name,
        string calldata _ticker,
        string calldata _description,
        string calldata _image
    ) external onlyOwner {
        if (_creator != address(0)) {
            require(
                memedTokenSale.isMintable(_creator),
                "Creator is blocked or already has a token"
            );
        }
        uint256 id = memedTokenSale.startFairLaunch(_creator);
        TokenData storage token = tokenData[id];
        token.creator = _creator;
        token.name = _name;
        token.ticker = _ticker;
        token.description = _description;
        token.image = _image;
        token.isClaimedByCreator = _creator != address(0);
        tokenRewardData[id].lastRewardAt = INITIAL_REWARDS_PER_HEAT;
        emit TokenCreated(
            id,
            token.token,
            token.creator,
            token.name,
            token.ticker,
            token.description,
            token.image,
            token.isClaimedByCreator,
            block.timestamp
        );
    }

    function claimToken(
        address _token,
        address _creator
    ) external nonReentrant onlyOwner {
        TokenData storage token = tokenData[memedTokenSale.tokenIdByAddress(_token)];
        require(token.creator == _creator, "Creator mismatch");
        require(!token.isClaimedByCreator, "Already claimed by creator");
        require(
            !memedTokenSale.isMintable(_creator),
            "Creator already has a token"
        );
        token.isClaimedByCreator = true;
        // Reset lastRewardAt to current heat when creator claims
        TokenRewardData storage rewardData = tokenRewardData[memedTokenSale.tokenIdByAddress(_token)];
        rewardData.lastRewardAt = rewardData.heat;
        IMemedToken(token.token).claimUnclaimedTokens(
            token.creator
        );
    }

    function updateHeat(HeatUpdate[] calldata _heatUpdates) public {
        require(
            msg.sender == address(memedBattle) || msg.sender == memedBattle.getResolver() || msg.sender == owner(),
            "unauthorized"
        );

        // Convert calldata to memory for internal processing
        HeatUpdate[] memory heatUpdatesMemory = new HeatUpdate[](
            _heatUpdates.length
        );
        for (uint i = 0; i < _heatUpdates.length; i++) {
            heatUpdatesMemory[i] = _heatUpdates[i];
        }

        _updateHeatInternal(heatUpdatesMemory);
    }

    function _updateHeatInternal(HeatUpdate[] memory _heatUpdates) internal {
        for (uint i = 0; i < _heatUpdates.length; i++) {
            TokenData storage token = tokenData[memedTokenSale.tokenIdByAddress(_heatUpdates[i].token)];
            require(token.token != address(0), "Token not created");
            TokenRewardData storage tokenReward = tokenRewardData[
                memedTokenSale.tokenIdByAddress(_heatUpdates[i].token)
            ];
            require(
                block.timestamp >= tokenReward.lastHeatUpdate + 1 days,
                "Heat update too frequent"
            );

            // Store old heat for comparison
            uint256 oldHeat = tokenReward.heat;
            uint256 newHeat = _heatUpdates[i].heat;
            
            // Update heat value and timestamp
            tokenReward.heat = newHeat;
            tokenReward.lastHeatUpdate = block.timestamp;
            
            // Initialize lastRewardAt if this is first update after creation
            if (tokenReward.lastRewardAt == INITIAL_REWARDS_PER_HEAT && oldHeat == 0) {
                tokenReward.lastRewardAt = 0;
            }

            // Check if engagement rewards should be unlocked
            if (
                (tokenReward.heat - tokenReward.lastRewardAt) >=
                ENGAGEMENT_REWARDS_PER_NEW_HEAT &&
                memedEngageToEarn.isRewardable(token.token)
            ) {
                memedEngageToEarn.registerEngagementReward(token.token);
                tokenReward.lastRewardAt = tokenReward.heat;
            }

            // Check if creator incentives should be unlocked
            if (
                token.isClaimedByCreator &&
                tokenReward.heat - tokenReward.creatorIncentivesUnlockedAt >=
                tokenReward.creatorIncentivesUnlocksAt &&
                IMemedToken(token.token).isRewardable()
            ) {
                tokenReward.creatorIncentivesUnlockedAt = tokenReward.heat;
                IMemedToken(token.token).unlockCreatorIncentives();
            }

            emit HeatUpdated(
                _heatUpdates[i].token,
                tokenReward.heat,
                block.timestamp
            );
        }
    }

    function battleUpdate(address _winner, address _loser) external {
        require(msg.sender == address(memedBattle) || msg.sender == memedBattle.getResolver(), "unauthorized");
        TokenRewardData storage token = tokenRewardData[
            memedTokenSale.tokenIdByAddress(_winner)
        ];
        TokenRewardData storage tokenLoser = tokenRewardData[
            memedTokenSale.tokenIdByAddress(_loser)
        ];
        token.creatorIncentivesUnlocksAt =
            token.creatorIncentivesUnlocksAt -
            ((token.creatorIncentivesUnlocksAt * BATTLE_REWARDS_PERCENTAGE) /
                100);
        tokenLoser.creatorIncentivesUnlocksAt =
            tokenLoser.creatorIncentivesUnlocksAt +
            ((tokenLoser.creatorIncentivesUnlocksAt *
                BATTLE_REWARDS_PERCENTAGE) / 100);
        emit BattleUpdated(
            _winner,
            _loser,
            token.creatorIncentivesUnlocksAt,
            tokenLoser.creatorIncentivesUnlocksAt
        );
    }

    function completeFairLaunch(
        uint256 _id,
        address _token,
        address _warriorNFT
    ) external onlyOwner {
        TokenData storage token = tokenData[_id];
        (FairLaunchStatus status, uint256 ethAmount) = memedTokenSale.getFairLaunchData(_id);
        require(status == FairLaunchStatus.READY_TO_COMPLETE, "Fair launch not ready to complete");
        
        IMemedToken(_token).allocateLp();
        token.token = _token;
        token.warriorNFT = _warriorNFT;
        tokens.push(_token);
        emit TokenCompletedFairLaunch(_id, _token, _warriorNFT);
        
        address pool = _createAndInitializePool(_token);
        _addLiquidityToPool(_token, IMemedToken(_token).LP_ALLOCATION(), ethAmount);
        
        memedTokenSale.completeFairLaunch(_id, _token, pool);
    }
    
    function _createAndInitializePool(address _token) internal returns (address pool) {
        pool = uniswapV3Factory.createPool(_token, MEMED_TEST_ETH, POOL_FEE);
        
        uint160 sqrtPriceX96 = _token < MEMED_TEST_ETH
            ? 50108084819137649406
            : 1582517825267090392187392094;
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
    }
    
    function _addLiquidityToPool(address _token, uint256 tokenAmount, uint256 ethAmount) internal {
        (address token0, address token1) = _token < MEMED_TEST_ETH ? (_token, MEMED_TEST_ETH) : (MEMED_TEST_ETH, _token);
        (uint256 amount0, uint256 amount1) = _token < MEMED_TEST_ETH ? (tokenAmount, ethAmount) : (ethAmount, tokenAmount);
        
        IERC20(token0).approve(address(positionManager), amount0);
        IERC20(token1).approve(address(positionManager), amount1);

        (uint256 tokenId, , , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 300
            })
        );
        
        // Store the LP NFT token ID for future fee collection
        lpTokenIds[_token] = tokenId;
    }

    function swap(
        uint256 _amount,
        address[] calldata _path,
        address _to
    ) external nonReentrant returns (uint256) {
        require(
            msg.sender == address(memedBattle) ||
                msg.sender == address(memedEngageToEarn),
            "Only battle or engage to earn can swap"
        );
        require(_path.length >= 2, "Invalid path");
        
        IERC20(_path[0]).approve(address(swapRouter), _amount);
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _path[0],
            tokenOut: _path[_path.length - 1],
            fee: POOL_FEE,
            recipient: _to,
            deadline: block.timestamp + 300,
            amountIn: _amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        
        uint256 amountOut = swapRouter.exactInputSingle(params);
        return amountOut;
    }

    /**
     * @dev Collect accumulated swap fees from a Uniswap V3 LP position
     * @param _token The token address for which to collect fees
     * @return amount0 Amount of token0 fees collected
     * @return amount1 Amount of token1 fees collected
     */
    function collectFees(address _token) external onlyOwner returns (uint256 amount0, uint256 amount1) {
        uint256 tokenId = lpTokenIds[_token];
        require(tokenId != 0, "No LP position for this token");
        
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: owner(),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    function getByToken(address _token) public view returns (TokenData memory) {
        return tokenData[memedTokenSale.tokenIdByAddress(_token)];
    }

    function getWarriorNFT(address _token) external view returns (address) {
        return tokenData[memedTokenSale.tokenIdByAddress(_token)].warriorNFT;
    }

    function getCreatorById(uint256 _id) external view returns (address) {
        return tokenData[_id].creator;
    }

    function getHeat(address _token) external view returns (uint256) {
        return tokenRewardData[memedTokenSale.tokenIdByAddress(_token)].heat;
    }

    function getTokenByAddress(
        address _token
    ) public view returns (TokenData memory) {
        TokenData memory token = tokenData[
            memedTokenSale.tokenIdByAddress(_token)
        ];
        require(token.token != address(0), "Token not created");
        return token;
    }

    function getTokenById(
        uint256 _id
    ) external view returns (TokenData memory) {
        return tokenData[_id];
    }

    function getMemedEngageToEarn() external view returns (IMemedEngageToEarn) {
        return memedEngageToEarn;
    }

    function getMemedBattle() external view returns (address) {
        return address(memedBattle);
    }

    function getTokens() external view returns (TokenData[] memory) {
        TokenData[] memory result = new TokenData[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            result[i] = getTokenByAddress(tokens[i]);
        }
        return result;
    }

    receive() external payable {}
}
