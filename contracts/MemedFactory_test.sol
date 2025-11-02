// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IMemedBattle.sol";
import "../interfaces/IUniswapV2.sol";
import "../interfaces/IMemedToken.sol";
import "../interfaces/IMemedTokenSale.sol";
import "../interfaces/IMemedEngageToEarn.sol";
import "../structs/FactoryStructs.sol";

contract MemedFactory_test is Ownable, ReentrancyGuard {
    address public constant MEMED_TEST_ETH = 0xc190e6F26cE14e40D30251fDe25927A73a5D58b6;
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
    address[] public tokens;
    IUniswapV2Router02 public uniswapV2Router;
    IUniswapV2Factory public uniswapV2Factory;

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
        address _uniswapV2Router
    ) Ownable(msg.sender) {
        memedTokenSale = IMemedTokenSale(_memedTokenSale);
        memedBattle = IMemedBattle(_memedBattle);
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
        TokenData storage token = tokenData[id];
        token.creator = _creator;
        token.name = _name;
        token.ticker = _ticker;
        token.description = _description;
        token.image = _image;
        token.isClaimedByCreator = _creator == address(0);
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
        TokenData memory token = getTokenByAddress(_token);
        require(token.creator == _creator, "Creator mismatch");
        require(!token.isClaimedByCreator, "Already claimed by creator");
        require(!memedTokenSale.isMintable(_creator), "Creator already has a token");
        token.isClaimedByCreator = true;
        tokenRewardData[memedTokenSale.tokenIdByAddress(_token)].lastRewardAt = tokenRewardData[memedTokenSale.tokenIdByAddress(_token)].heat;
        IMemedToken(token.token).claim(
            token.creator,
            (memedTokenSale.INITIAL_SUPPLY() * 5) / 100
        );
    }

    function updateHeat(HeatUpdate[] calldata _heatUpdates) public {
        require(
            msg.sender == address(memedBattle) || msg.sender == owner(),
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
        address _token,
        address _warriorNFT
    ) external onlyOwner {
        TokenData memory token = tokenData[_id];
        (FairLaunchStatus status, uint256 ethAmount) = memedTokenSale.getFairLaunchData(_id);
        require(status == FairLaunchStatus.READY_TO_COMPLETE, "Fair launch not ready to complete");
        uint256 tokenAmount = IMemedToken(_token).LP_ALLOCATION();
        IMemedToken(_token).allocateLp();
        token.token = _token;
        token.warriorNFT = _warriorNFT;
        tokens.push(_token);
        emit TokenCompletedFairLaunch(_id, _token, _warriorNFT);
        address pair = uniswapV2Factory.createPair(
            _token,
            MEMED_TEST_ETH
        );
        
        // Approve router to spend tokens and test ETH
        IERC20(_token).approve(address(uniswapV2Router), IMemedToken(_token).LP_ALLOCATION());
        IERC20(MEMED_TEST_ETH).approve(address(uniswapV2Router), ethAmount);

        // Add liquidity to Uniswap with test ETH tokens
        uniswapV2Router.addLiquidity(
            _token,
            MEMED_TEST_ETH,
            tokenAmount,
            ethAmount,
            0,
            0,
            address(0),
            block.timestamp + 300
        );

        memedTokenSale.completeFairLaunch(_id, _token, pair);
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
