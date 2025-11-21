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
import "../interfaces/IWETH.sol";
import "../libraries/TickMath.sol";
import "../libraries/FullMath.sol";

/// @title Memed Factory
/// @notice Manages token creation, liquidity provisioning, and reward distribution
contract MemedFactory is Ownable, ReentrancyGuard {
    uint256 public constant REWARD_PER_ENGAGEMENT = 100000;
    uint256 public constant MAX_ENGAGE_USER_REWARD_PERCENTAGE = 2;
    uint256 public constant MAX_ENGAGE_CREATOR_REWARD_PERCENTAGE = 1;

    address public constant WETH = 0x4200000000000000000000000000000000000006;

    uint256 public INITIAL_REWARDS_PER_HEAT = 100000;
    uint256 public BATTLE_REWARDS_PERCENTAGE = 20;

    uint256 public constant ENGAGEMENT_REWARDS_PER_NEW_HEAT = 100000;
    uint256 public constant CREATOR_INCENTIVE_STEP = 100000;

    IMemedTokenSale public memedTokenSale;
    IMemedBattle public memedBattle;
    IMemedEngageToEarn public memedEngageToEarn;

    mapping(uint256 => TokenData) public tokenData;
    mapping(uint256 => TokenRewardData) public tokenRewardData;
    mapping(address => uint256) public lpTokenIds;
    address[] public tokens;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public uniswapV3Factory;
    ISwapRouter public swapRouter;
    uint24 public constant POOL_FEE = 3000;
    event TokenCreated(
        uint256 indexed id,
        address indexed token,
        address indexed owner,
        bool isClaimedByCreator,
        uint256 endTime
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

    /// @notice Start a new fair launch for a token
    /// @param _creator The address of the token creator
    function startFairLaunch(address _creator) external onlyOwner {
        if (_creator != address(0)) {
            require(
                memedTokenSale.isMintable(_creator),
                "Creator is blocked or already has a token"
            );
        }
        (uint256 id, uint256 endTime) = memedTokenSale.startFairLaunch(_creator);
        TokenData storage token = tokenData[id];
        token.creator = _creator;
        token.isClaimedByCreator = _creator != address(0);
        tokenRewardData[id].lastRewardAt = INITIAL_REWARDS_PER_HEAT;
        emit TokenCreated(
            id,
            token.token,
            token.creator,
            token.isClaimedByCreator,
            endTime
        );
    }

    /// @notice Claim a token for a creator who was not the initial launcher
    /// @param _token The token address to claim
    /// @param _creator The creator address claiming the token
    function claimToken(
        address _token,
        address _creator
    ) external nonReentrant onlyOwner {
        TokenData storage token = tokenData[
            memedTokenSale.tokenIdByAddress(_token)
        ];
        require(token.token != address(0), "Token not created");
        require(token.creator == _creator, "Creator mismatch");
        require(!token.isClaimedByCreator, "Already claimed by creator");
        require(
            !memedTokenSale.isMintable(_creator),
            "Creator already has a token"
        );
        token.isClaimedByCreator = true;
        TokenRewardData storage rewardData = tokenRewardData[
            memedTokenSale.tokenIdByAddress(_token)
        ];
        rewardData.lastRewardAt = rewardData.heat;
        rewardData.creatorIncentivesUnlockedAt = rewardData.heat;
        memedEngageToEarn.claimUnclaimedTokens(token.token, token.creator);
    }

    /// @notice Update heat scores for multiple tokens
    /// @param _heatUpdates Array of heat updates containing token addresses and new heat values
    function updateHeat(HeatUpdate[] calldata _heatUpdates) public {
        require(
            msg.sender == address(memedBattle) ||
                msg.sender == memedBattle.getResolver() ||
                msg.sender == owner(),
            "unauthorized"
        );
        HeatUpdate[] memory m = new HeatUpdate[](_heatUpdates.length);
        for (uint i = 0; i < _heatUpdates.length; i++) m[i] = _heatUpdates[i];
        _updateHeatInternal(m);
    }

    /// @dev Internal function to update heat and process rewards
    /// @param _heatUpdates Array of heat updates to process
    function _updateHeatInternal(HeatUpdate[] memory _heatUpdates) internal {
        for (uint i = 0; i < _heatUpdates.length; i++) {
            TokenData storage token = tokenData[
                memedTokenSale.tokenIdByAddress(_heatUpdates[i].token)
            ];
            require(token.token != address(0), "Token not created");
            TokenRewardData storage tokenReward = tokenRewardData[
                memedTokenSale.tokenIdByAddress(_heatUpdates[i].token)
            ];

            require(
                tokenReward.lastHeatUpdate == 0 ||
                    block.timestamp >= tokenReward.lastHeatUpdate + 1 days ||
                    msg.sender == memedBattle.getResolver(),
                "Heat update too frequent"
            );

            uint256 oldHeat = tokenReward.heat;
            uint256 newHeat = _heatUpdates[i].heat;
            require(newHeat >= oldHeat, "Invalid heat decrease");

            tokenReward.heat = newHeat;
            tokenReward.lastHeatUpdate = block.timestamp;

            if (
                tokenReward.lastRewardAt == INITIAL_REWARDS_PER_HEAT &&
                oldHeat == 0
            ) {
                tokenReward.lastRewardAt = 0;
            }

            if (memedEngageToEarn.isRewardable(token.token)) {
                uint256 rewardableHeat = tokenReward.heat -
                    tokenReward.lastRewardAt;
                uint256 rewardsCount = rewardableHeat /
                    ENGAGEMENT_REWARDS_PER_NEW_HEAT;
                if (rewardsCount > 0) {
                    for (uint256 j = 0; j < rewardsCount; j++) {
                        memedEngageToEarn.registerEngagementReward(token.token);
                    }
                    tokenReward.lastRewardAt +=
                        rewardsCount *
                        ENGAGEMENT_REWARDS_PER_NEW_HEAT;
                }
            }

            if (
                token.isClaimedByCreator &&
                memedEngageToEarn.isCreatorRewardable(token.token)
            ) {
                if (tokenReward.creatorIncentivesUnlocksAt == 0) {
                    tokenReward
                        .creatorIncentivesUnlocksAt = CREATOR_INCENTIVE_STEP;
                }
                uint256 rewardableCreatorHeat = tokenReward.heat -
                    tokenReward.creatorIncentivesUnlockedAt;
                uint256 unlocksCount = rewardableCreatorHeat /
                    tokenReward.creatorIncentivesUnlocksAt;
                if (unlocksCount > 0) {
                    for (uint256 k = 0; k < unlocksCount; k++) {
                        memedEngageToEarn.unlockCreatorIncentives(token.token);
                    }
                    tokenReward.creatorIncentivesUnlockedAt +=
                        unlocksCount *
                        tokenReward.creatorIncentivesUnlocksAt;
                }
            }

            emit HeatUpdated(
                _heatUpdates[i].token,
                tokenReward.heat,
                block.timestamp
            );
        }
    }

    /// @notice Update token rewards based on battle outcome
    /// @param _winner Address of the winning token
    /// @param _loser Address of the losing token
    function battleUpdate(address _winner, address _loser) external {
        require(
            msg.sender == address(memedBattle) ||
                msg.sender == memedBattle.getResolver(),
            "unauthorized"
        );
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

    /// @notice Complete a fair launch and deploy Uniswap pool
    /// @param _id The fair launch ID
    /// @param _token The deployed token address
    /// @param _warriorNFT The deployed warrior NFT address
    function completeFairLaunch(
        uint256 _id,
        address _token,
        address _warriorNFT
    ) external onlyOwner {
        TokenData storage token = tokenData[_id];
        require(memedTokenSale.isCompletable(_id), "not completable");

        memedTokenSale.finalizeSale(_id);
        token.token = _token;
        token.warriorNFT = _warriorNFT;
        tokens.push(_token);
        emit TokenCompletedFairLaunch(_id, _token, _warriorNFT);

        address pool = _createAndInitializePool(_token);
        uint256 lpTokenId = _addLiquidityToPool(
            _token,
            IMemedToken(_token).LP_ALLOCATION(),
            memedTokenSale.LP_ETH()
        );
        lpTokenIds[_token] = lpTokenId;
        memedTokenSale.completeFairLaunch(_id, _token, pool);
        if (token.isClaimedByCreator) {
            tokenRewardData[_id].creatorIncentivesUnlockedAt = 0;
            memedEngageToEarn.claimUnclaimedTokens(_token, token.creator);
        }
    }

    /// @dev Calculate the square root of a uint256
    /// @param x The value to calculate square root for
    /// @return r The square root
    function _sqrtRatio(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 z = (x + 1) >> 1;
        r = x;
        while (z < r) {
            r = z;
            z = (x / z + z) >> 1;
        }
    }

    /// @dev Encode the sqrt price as a Q64.96 value
    /// @param amount1 The amount of token1
    /// @param amount0 The amount of token0
    /// @return The sqrt price encoded as Q64.96
    function encodeSqrtRatioX96(
        uint256 amount1,
        uint256 amount0
    ) internal pure returns (uint160) {
        require(amount0 > 0 && amount1 > 0, "bad ratio");
        uint256 ratioX192 = FullMath.mulDiv(
            amount1,
            uint256(1) << 192,
            amount0
        );
        uint256 sqrtX96 = _sqrtRatio(ratioX192);
        require(sqrtX96 <= type(uint160).max, "sqrt overflow");
        return uint160(sqrtX96);
    }

    /// @dev Round tick to nearest valid tick spacing
    /// @param tick The tick to round
    /// @param spacing The tick spacing
    /// @param down Whether to round down or up
    /// @return The rounded tick
    function _roundToSpacing(
        int24 tick,
        int24 spacing,
        bool down
    ) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem == 0) return tick;
        return
            down
                ? tick - rem - (tick < 0 ? spacing : int24(0))
                : tick - rem + (tick > 0 ? spacing : int24(0));
    }

    /// @dev Create and initialize a Uniswap V3 pool for the token
    /// @param _token The token address to create pool for
    /// @return pool The address of the created pool
    function _createAndInitializePool(
        address _token
    ) internal returns (address pool) {
        (address token0, address token1) = _token < WETH
            ? (_token, WETH)
            : (WETH, _token);

        uint256 amountToken = IMemedToken(_token).LP_ALLOCATION();
        uint256 amountEth = memedTokenSale.LP_ETH();
        require(amountToken > 0 && amountEth > 0, "zero amounts");

        uint256 amount0 = token0 == _token ? amountToken : amountEth;
        uint256 amount1 = token0 == _token ? amountEth : amountToken;

        address existing = uniswapV3Factory.getPool(token0, token1, POOL_FEE);
        if (existing != address(0)) revert("POOL_EXISTS");

        uint160 sqrtPriceX96 = encodeSqrtRatioX96(amount1, amount0);

        pool = IUniswapV3Factory(uniswapV3Factory).createPool(
            token0,
            token1,
            POOL_FEE
        );

        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
    }

    /// @dev Add liquidity to the Uniswap V3 pool
    /// @param _token The token address
    /// @param tokenAmount The amount of tokens to add
    /// @param ethAmount The amount of ETH to add
    /// @return The LP NFT token ID
    function _addLiquidityToPool(
        address _token,
        uint256 tokenAmount,
        uint256 ethAmount
    ) internal returns (uint256) {
        (address token0, address token1) = _token < WETH
            ? (_token, WETH)
            : (WETH, _token);

        uint256 amount0Desired = token0 == _token ? tokenAmount : ethAmount;
        uint256 amount1Desired = token0 == _token ? ethAmount : tokenAmount;

        if (IERC20(_token).balanceOf(address(this)) < tokenAmount)
            revert("MISSING_BALANCE_TOKEN");
        if (address(this).balance < ethAmount) revert("MISSING_BALANCE_ETH");

        uint160 sqrtPriceX96 = encodeSqrtRatioX96(
            token0 == _token ? ethAmount : tokenAmount,
            token0 == _token ? tokenAmount : ethAmount
        );

        int24 initialTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        int24 spacing = 60;
        int24 rawLower = initialTick - 10_000;
        int24 rawUpper = initialTick + 10_000;

        int24 tickLower = _roundToSpacing(rawLower, spacing, true);
        int24 tickUpper = _roundToSpacing(rawUpper, spacing, false);

        if (tickLower < TickMath.MIN_TICK)
            tickLower = TickMath.MIN_TICK - (TickMath.MIN_TICK % spacing);
        if (tickUpper > TickMath.MAX_TICK)
            tickUpper = TickMath.MAX_TICK - (TickMath.MAX_TICK % spacing);

        IERC20(token0).approve(address(positionManager), amount0Desired);
        IERC20(token1).approve(address(positionManager), amount1Desired);
        IWETH(WETH).deposit{value: ethAmount}();

        (uint256 lpTokenId, , , ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 600
            })
        );
        return lpTokenId;
    }

    /// @notice Swap tokens through Uniswap V3
    /// @param _amount The amount of input tokens to swap
    /// @param _path The swap path (must route through WETH)
    /// @param _to The recipient address
    /// @return The amount of output tokens received
    function swap(
        uint256 _amount,
        address[] calldata _path,
        address _to
    ) external nonReentrant returns (uint256) {
        require(
            msg.sender == address(memedEngageToEarn),
            "Only engage to earn can swap"
        );
        require(_path.length >= 2, "Invalid path");

        address tokenIn = _path[0];
        address tokenOut = _path[_path.length - 1];

        address p1 = IUniswapV3Factory(uniswapV3Factory).getPool(
            tokenIn,
            WETH,
            POOL_FEE
        );
        address p2 = IUniswapV3Factory(uniswapV3Factory).getPool(
            WETH,
            tokenOut,
            POOL_FEE
        );
        require(p1 != address(0) && p2 != address(0), "missing pool");

        IERC20(tokenIn).approve(address(swapRouter), _amount);

        bytes memory path = abi.encodePacked(
            tokenIn,
            POOL_FEE,
            WETH,
            POOL_FEE,
            tokenOut
        );

        ISwapRouter.ExactInputParams memory params = ISwapRouter
            .ExactInputParams({
                path: path,
                recipient: _to,
                amountIn: _amount,
                amountOutMinimum: 0
            });

        uint256 amountOut = swapRouter.exactInput(params);
        return amountOut;
    }

    /// @notice Collect accumulated swap fees from a Uniswap V3 LP position
    /// @param _token The token address for which to collect fees
    /// @return amount0 Amount of token0 fees collected
    /// @return amount1 Amount of token1 fees collected
    function collectFees(
        address _token
    ) external onlyOwner returns (uint256 amount0, uint256 amount1) {
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

    /// @notice Get token data by token address
    /// @param _token The token address
    /// @return TokenData struct containing token information
    function getByToken(address _token) public view returns (TokenData memory) {
        return tokenData[memedTokenSale.tokenIdByAddress(_token)];
    }

    /// @notice Get the warrior NFT address for a token
    /// @param _token The token address
    /// @return The warrior NFT contract address
    function getWarriorNFT(address _token) external view returns (address) {
        return tokenData[memedTokenSale.tokenIdByAddress(_token)].warriorNFT;
    }

    /// @notice Get the creator address by token ID
    /// @param _id The token ID
    /// @return The creator address
    function getCreatorById(uint256 _id) external view returns (address) {
        return tokenData[_id].creator;
    }

    /// @notice Get the current heat score for a token
    /// @param _token The token address
    /// @return The current heat score
    function getHeat(address _token) external view returns (uint256) {
        return tokenRewardData[memedTokenSale.tokenIdByAddress(_token)].heat;
    }

    /// @notice Get token data by address with validation
    /// @param _token The token address
    /// @return TokenData struct containing token information
    function getTokenByAddress(
        address _token
    ) public view returns (TokenData memory) {
        TokenData memory token = tokenData[
            memedTokenSale.tokenIdByAddress(_token)
        ];
        require(token.token != address(0), "Token not created");
        return token;
    }

    /// @notice Get token data by ID
    /// @param _id The token ID
    /// @return TokenData struct containing token information
    function getTokenById(
        uint256 _id
    ) external view returns (TokenData memory) {
        return tokenData[_id];
    }

    /// @notice Get the Memed Engage To Earn contract instance
    /// @return The IMemedEngageToEarn interface
    function getMemedEngageToEarn() external view returns (IMemedEngageToEarn) {
        return memedEngageToEarn;
    }

    /// @notice Get the Memed Battle contract address
    /// @return The battle contract address
    function getMemedBattle() external view returns (address) {
        return address(memedBattle);
    }

    /// @notice Get all tokens
    /// @return Array of TokenData structs for all tokens
    function getTokens() external view returns (TokenData[] memory) {
        TokenData[] memory result = new TokenData[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            result[i] = getTokenByAddress(tokens[i]);
        }
        return result;
    }

    receive() external payable {}
}
