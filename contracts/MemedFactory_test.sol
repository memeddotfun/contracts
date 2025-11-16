// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IMemedBattle.sol";
import "../interfaces/IUniswapV3.sol";
import "../interfaces/IMemedToken.sol";
import "../interfaces/IMemedTokenSale.sol";
import "../interfaces/IMemedEngageToEarn.sol";
import "../structs/FactoryStructs.sol";
import "../libraries/TickMath.sol";
import "../libraries/FullMath.sol";

contract MemedFactory_test is Ownable, ReentrancyGuard {
    address public constant MEMED_TEST_ETH =
        0xc190e6F26cE14e40D30251fDe25927A73a5D58b6;

    uint256 public constant REWARD_PER_ENGAGEMENT = 100000;
    uint256 public constant MAX_ENGAGE_USER_REWARD_PERCENTAGE = 2;
    uint256 public constant MAX_ENGAGE_CREATOR_REWARD_PERCENTAGE = 1;

    uint256 public INITIAL_REWARDS_PER_HEAT = 100000;
    uint256 public BATTLE_REWARDS_PERCENTAGE = 20;
    uint256 public constant ENGAGEMENT_REWARDS_PER_NEW_HEAT = 50000;
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

    function startFairLaunch(address _creator) external onlyOwner {
        if (_creator != address(0)) {
            require(
                memedTokenSale.isMintable(_creator),
                "creator blocked/has token"
            );
        }
        uint256 id = memedTokenSale.startFairLaunch(_creator);
        TokenData storage t = tokenData[id];
        t.creator = _creator;
        t.isClaimedByCreator = _creator != address(0);
        tokenRewardData[id].lastRewardAt = INITIAL_REWARDS_PER_HEAT;

        emit TokenCreated(
            id,
            t.token,
            t.creator,
            t.isClaimedByCreator,
            block.timestamp
        );
    }

    function claimToken(
        address _token,
        address _creator
    ) external nonReentrant onlyOwner {
        TokenData storage t = tokenData[
            memedTokenSale.tokenIdByAddress(_token)
        ];
        require(t.creator == _creator, "creator mismatch");
        require(!t.isClaimedByCreator, "already claimed");
        require(
            !memedTokenSale.isMintable(_creator),
            "creator already has token"
        );
        t.isClaimedByCreator = true;
        TokenRewardData storage r = tokenRewardData[
            memedTokenSale.tokenIdByAddress(_token)
        ];
        r.lastRewardAt = r.heat;
        r.creatorIncentivesUnlockedAt = CREATOR_INCENTIVE_STEP;
        memedEngageToEarn.claimUnclaimedTokens(t.token, t.creator);
    }

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

    function battleUpdate(address _winner, address _loser) external {
        require(
            msg.sender == address(memedBattle) ||
                msg.sender == memedBattle.getResolver(),
            "unauthorized"
        );
        TokenRewardData storage w = tokenRewardData[
            memedTokenSale.tokenIdByAddress(_winner)
        ];
        TokenRewardData storage l = tokenRewardData[
            memedTokenSale.tokenIdByAddress(_loser)
        ];
        w.creatorIncentivesUnlocksAt =
            w.creatorIncentivesUnlocksAt -
            ((w.creatorIncentivesUnlocksAt * BATTLE_REWARDS_PERCENTAGE) / 100);
        l.creatorIncentivesUnlocksAt =
            l.creatorIncentivesUnlocksAt +
            ((l.creatorIncentivesUnlocksAt * BATTLE_REWARDS_PERCENTAGE) / 100);
        emit BattleUpdated(
            _winner,
            _loser,
            w.creatorIncentivesUnlocksAt,
            l.creatorIncentivesUnlocksAt
        );
    }

    function completeFairLaunch(
        uint256 _id,
        address _token,
        address _warriorNFT
    ) external onlyOwner {
        TokenData storage t = tokenData[_id];
        FairLaunchStatus status = memedTokenSale.getFairLaunchStatus(_id);
        require(status == FairLaunchStatus.READY_TO_COMPLETE, "not ready");

        t.token = _token;
        t.warriorNFT = _warriorNFT;
        tokens.push(_token);
        emit TokenCompletedFairLaunch(_id, _token, _warriorNFT);

        address pool = _createAndInitializePool(_token);
        uint256 tokenId = _addLiquidityToPool(
            _token,
            IMemedToken(_token).LP_ALLOCATION(),
            memedTokenSale.LP_ETH()
        );
        lpTokenIds[_token] = tokenId;
        memedTokenSale.completeFairLaunch(_id, _token, pool);
        if (t.isClaimedByCreator) {
            memedEngageToEarn.claimUnclaimedTokens(_token, t.creator);
            tokenRewardData[_id]
                .creatorIncentivesUnlockedAt = CREATOR_INCENTIVE_STEP;
        }
    }

    function _sqrtRatio(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 z = (x + 1) >> 1;
        r = x;
        while (z < r) {
            r = z;
            z = (x / z + z) >> 1;
        }
    }

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

    function _createAndInitializePool(
        address _token
    ) internal returns (address pool) {
        (address token0, address token1) = _token < MEMED_TEST_ETH
            ? (_token, MEMED_TEST_ETH)
            : (MEMED_TEST_ETH, _token);

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

    function _addLiquidityToPool(
        address _token,
        uint256 tokenAmount,
        uint256 ethAmount
    ) internal returns (uint256 tokenId) {
        (address token0, address token1) = _token < MEMED_TEST_ETH
            ? (_token, MEMED_TEST_ETH)
            : (MEMED_TEST_ETH, _token);

        uint256 amount0Desired = token0 == _token ? tokenAmount : ethAmount;
        uint256 amount1Desired = token0 == _token ? ethAmount : tokenAmount;

        if (IERC20(token0).balanceOf(address(this)) < amount0Desired)
            revert("MISSING_BALANCE_TOKEN0");
        if (IERC20(token1).balanceOf(address(this)) < amount1Desired)
            revert("MISSING_BALANCE_TOKEN1");

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

    function swap(
        uint256 _amount,
        address[] calldata _path,
        address _to
    ) external nonReentrant returns (uint256) {
        require(
            msg.sender == address(memedEngageToEarn),
            "Only engage to earn can swap"
        );
        require(_path.length >= 2, "path");
        address tokenIn = _path[0];
        address tokenOut = _path[_path.length - 1];

        address p1 = IUniswapV3Factory(uniswapV3Factory).getPool(
            tokenIn,
            MEMED_TEST_ETH,
            POOL_FEE
        );
        address p2 = IUniswapV3Factory(uniswapV3Factory).getPool(
            MEMED_TEST_ETH,
            tokenOut,
            POOL_FEE
        );
        require(p1 != address(0) && p2 != address(0), "missing pool");

        IERC20(tokenIn).approve(address(swapRouter), _amount);

        bytes memory path = abi.encodePacked(
            tokenIn,
            POOL_FEE,
            MEMED_TEST_ETH,
            POOL_FEE,
            tokenOut
        );

        return
            swapRouter.exactInput(
                ISwapRouter.ExactInputParams({
                    path: path,
                    recipient: _to,
                    amountIn: _amount,
                    amountOutMinimum: 0
                })
            );
    }

    function collectFees(
        address _token
    ) external onlyOwner returns (uint256 amount0, uint256 amount1) {
        uint256 tokenId = lpTokenIds[_token];
        require(tokenId != 0, "no LP");
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
        TokenData memory t = tokenData[memedTokenSale.tokenIdByAddress(_token)];
        require(t.token != address(0), "not created");
        return t;
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
