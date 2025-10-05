// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./MemedToken.sol";
import "./MemedWarriorNFT.sol";
import "./MemedBattle.sol";
import "../interfaces/IUniswapV2.sol";
import "../interfaces/IMemedTokenSale.sol";
import "../interfaces/IMemedEngageToEarn.sol";
import "../structs/FactoryStructs.sol";

contract MemedFactory is Ownable, ReentrancyGuard {
    uint256 public constant REWARD_PER_ENGAGEMENT = 100000;
    uint256 public constant MAX_ENGAGE_USER_REWARD_PERCENTAGE = 2;
    uint256 public constant MAX_ENGAGE_CREATOR_REWARD_PERCENTAGE = 1;

    // Battle rewards
    uint256 public INITIAL_REWARDS_PER_HEAT = 100000; // 100,000 of heat will be required to unlock the battle rewards
    uint256 public BATTLE_REWARDS_PERCENTAGE = 20; // 20% of heat will be inceased or decreased based on the battle result


    // Engagement rewards
    uint256 public constant ENGAGEMENT_REWARDS_PER_NEW_HEAT = 50000; // For every 50,000 heat, 1 engagement reward is given

    IMemedTokenSale public memedTokenSale;
    MemedBattle public memedBattle;
    IMemedEngageToEarn public memedEngageToEarn;

    mapping(uint256 => TokenData) public tokenData;
    mapping(uint256 => TokenRewardData) public tokenRewardData;
    address[] public tokens;
    IUniswapV2Router02 public uniswapV2Router;
    IUniswapV2Factory public uniswapV2Factory;

    // Events
    event TokenCreated(
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
        address _uniswapV2Router
    ) Ownable(msg.sender) {
        memedTokenSale = IMemedTokenSale(_memedTokenSale);
        memedBattle = MemedBattle(_memedBattle);
        memedEngageToEarn = IMemedEngageToEarn(_memedEngageToEarn);
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        uniswapV2Factory = IUniswapV2Factory(uniswapV2Router.factory());
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
        TokenData memory token = tokenData[id];
        token.creator = _creator;
        token.name = _name;
        token.ticker = _ticker;
        token.description = _description;
        token.image = _image;
        token.isClaimedByCreator = _creator == address(0);
        tokenRewardData[id].lastRewardAt = INITIAL_REWARDS_PER_HEAT;
        emit TokenCreated(
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
        TokenData memory token = getTokenByAddress(_token);
        require(token.creator == _creator, "Creator mismatch");
        require(!token.isClaimedByCreator, "Already claimed by creator");
        require(!memedTokenSale.isMintable(_creator), "Creator already has a token");
        token.isClaimedByCreator = true;
        tokenRewardData[memedTokenSale.tokenIdByAddress(_token)].lastRewardAt = tokenRewardData[memedTokenSale.tokenIdByAddress(_token)].heat;
        MemedToken(token.token).claim(
            token.creator,
            (memedTokenSale.INITIAL_SUPPLY() * 5) / 100
        );
    }

    function _updateHeatInternal(HeatUpdate[] memory _heatUpdates) internal {
        for (uint i = 0; i < _heatUpdates.length; i++) {
            TokenData memory token = getTokenByAddress(_heatUpdates[i].token);
            require(token.token != address(0), "Token not created");
            TokenRewardData memory tokenReward = tokenRewardData[memedTokenSale.tokenIdByAddress(_heatUpdates[i].token)];
            require(
                block.timestamp >= tokenReward.lastRewardAt + 1 days,
                "Heat update too frequent"
            );

            tokenReward.lastRewardAt = block.timestamp;
            tokenReward.lastRewardAt = _heatUpdates[i].heat;
            tokenReward.heat +=
                _heatUpdates[i].heat -
                tokenReward.lastRewardAt;

            if (
                (tokenReward.heat - tokenReward.lastRewardAt) >=
                ENGAGEMENT_REWARDS_PER_NEW_HEAT &&
                memedEngageToEarn.isRewardable(token.token)
            ) {
                memedEngageToEarn.registerEngagementReward(token.token);
                tokenReward.lastRewardAt = tokenReward.heat;
            }

            if (
                token.isClaimedByCreator &&
                tokenReward.heat - tokenReward.creatorIncentivesUnlockedAt >=
                tokenReward.creatorIncentivesUnlocksAt &&
                MemedToken(token.token).isRewardable()
            ) {
                tokenReward.creatorIncentivesUnlockedAt = tokenReward.heat;
                MemedToken(token.token).unlockCreatorIncentives();
            }

            emit HeatUpdated(
                _heatUpdates[i].token,
                tokenReward.heat,
                block.timestamp
            );
        }
    }

    function battleUpdate(address _winner, address _loser) external {
        require(msg.sender == address(memedBattle), "unauthorized");
        TokenRewardData memory token = tokenRewardData[memedTokenSale.tokenIdByAddress(_winner)];
        TokenRewardData memory tokenLoser = tokenRewardData[memedTokenSale.tokenIdByAddress(_loser)];
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
        uint256 _tokenAmount,
        uint256 _tokenBAmount
    ) external returns (address, address) {
        require(msg.sender == address(memedTokenSale), "unauthorized");
        
        TokenData memory token = tokenData[_id];
        require(token.token == address(0), "Token already completed");
        MemedToken memedToken = new MemedToken(
            token.name,
            token.ticker,
            token.creator,
            address(memedEngageToEarn),
            _tokenAmount
        );
        MemedWarriorNFT memedWarriorNFT = new MemedWarriorNFT(
            address(memedToken),
            address(memedBattle)
        );
        token.token = address(memedToken);
        token.warriorNFT = address(memedWarriorNFT);
        tokens.push(address(memedToken));
        emit TokenCompletedFairLaunch(_id, address(memedToken), address(memedWarriorNFT));
        address pair = uniswapV2Factory.createPair(
            address(memedToken),
            uniswapV2Router.WETH()
        );
        
        // Approve router to spend tokens
        IERC20(address(memedToken)).approve(address(uniswapV2Router), _tokenAmount);

        // Add liquidity to Uniswap
        uniswapV2Router
            .addLiquidityETH{value: _tokenBAmount}(
            address(memedToken),
            _tokenAmount,
            0, // Accept any amount of tokens
            0, // Accept any amount of ETH
            address(0), // LP tokens go to zero address
            block.timestamp + 300 // 5 minute deadline
        );

        return (address(memedToken), pair);
    }

    function swap(
        uint256 _amount,
        address[] calldata _path,
        address _to
    ) external nonReentrant returns (uint256[] memory) {
        require(msg.sender == address(memedBattle) || msg.sender == address(memedEngageToEarn), "Only battle or engage to earn can swap");
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

    function getTokenByAddress(address _token) public view returns (TokenData memory) {
        TokenData memory token = tokenData[memedTokenSale.tokenIdByAddress(_token)];
        require(token.token != address(0), "Token not created");
        return token;
    }

    function getTokenById(uint256 _id) external view returns (TokenData memory) {
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
