// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMemedFactory_test {
    struct TokenData {
        address token;
        address warriorNFT;
        address creator;
        string name;
        string ticker;
        string description;
        string image;
    }
    function completeFairLaunch(uint256 _id, uint256 _tokenAmount, uint256 _tokenBAmount) external returns (address, address);
    function getMemedEngageToEarn() external view returns (address);
    function getTokenById(uint256 _id) external view returns (TokenData memory);
    function getMemedBattle() external view returns (address);
}

contract MemedTokenSale_test is Ownable, ReentrancyGuard {

    // Bonding curve parameters
    address public constant MEMED_TEST_ETH = 0xc190e6F26cE14e40D30251fDe25927A73a5D58b6;
    uint256 public constant FAIR_LAUNCH_DURATION = 30 days;
    uint256 public INITIAL_SUPPLY = 1000000000 * 1e18; // 1B token
    uint256 public constant DECIMALS = 1e18;
    uint256 public constant TOTAL_FOR_SALE = 200_000_000 * DECIMALS;
    uint256 public constant TARGET_ETH_WEI = 40 ether;
    uint256 public constant SCALE = 1e36;
    uint256 public constant SLOPE = 2000;
    uint256 public platformFeePercentage = 10; // 1% to platform (10/1000)
    uint256 public feeDenominator = 1000; // For 1% fee calculation
    IMemedFactory_test public memedFactory;

    enum FairLaunchStatus {
        NOT_STARTED,
        ACTIVE,
        COMPLETED,
        FAILED
    }

    struct Commitment {
        uint256 amount;
        uint256 tokenAmount;
        bool claimed;
        bool refunded;
    }

    struct FairLaunchData {
        FairLaunchStatus status;
        uint256 fairLaunchStartTime;
        uint256 totalCommitted;
        uint256 totalSold;
        address uniswapPair;
        mapping(address => Commitment) commitments;
        mapping(address => uint256) balance;
        uint256 createdAt;
    }

    uint256 public id;

    mapping(uint256 => FairLaunchData) public fairLaunchData;
    mapping(address => uint256[]) public tokenIdsByCreator;
    mapping(address => uint256) public tokenIdByAddress;
    mapping(address => uint256) public blockedCreators;

    // Events

    event FairLaunchStarted(
        uint256 indexed id,
        address indexed creator,
        uint256 startTime,
        uint256 endTime
    );

    event CommitmentMade(
        uint256 indexed id,
        address indexed user,
        uint256 amount
    );

    event FairLaunchCompleted(
        uint256 indexed id,
        address indexed token,
        address indexed warriorNFT,
        uint256 totalRaised
    );

    event FairLaunchFailed(
        uint256 indexed id,
        uint256 totalRaised
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

    event PlatformFeeCollected(
        uint256 indexed id,
        address indexed user,
        uint256 feeAmount,
        string transactionType
    );  

    event PlatformFeeSet(uint256 platformFeePercentage, uint256 feeDenominator);



    constructor() Ownable(msg.sender) {}

    function startFairLaunch(
        address _creator
    ) external returns (uint256) {
        if (_creator != address(0)) {
            require(
                isMintable(_creator),
                "Creator is blocked or already has a token"
            );
        }

        require(msg.sender == address(memedFactory), "Only factory can start fair launch");
        id++;

        FairLaunchData storage fairLaunch = fairLaunchData[id];
        fairLaunch.status = FairLaunchStatus.ACTIVE;
        fairLaunch.fairLaunchStartTime = block.timestamp;
        fairLaunch.createdAt = block.timestamp;
        tokenIdsByCreator[_creator].push(id);
        emit FairLaunchStarted(
            id,
            _creator,
            block.timestamp,
            block.timestamp + FAIR_LAUNCH_DURATION
        );
        return id;
    }

    function commitToFairLaunch(uint256 _id, uint256 _eth) external nonReentrant {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        require(
            fairLaunch.status == FairLaunchStatus.ACTIVE,
            "Fair launch not active"
        );
        require(
            block.timestamp <=
                fairLaunch.fairLaunchStartTime + FAIR_LAUNCH_DURATION,
            "Fair launch ended"
        );
        require(_eth > 0, "Must send ETH");
        IERC20(MEMED_TEST_ETH).transferFrom(msg.sender, address(this), _eth);

        // Calculate platform fee (1%)
        uint256 platformFee = (_eth * platformFeePercentage) / feeDenominator;
        uint256 ethAfterFee = _eth - platformFee;

        uint256 tokenAmount = getNativeToTokenAmount(_id, ethAfterFee);
        require(tokenAmount > 0, "Insufficient ETH");
        require(
            fairLaunch.totalSold + tokenAmount <= INITIAL_SUPPLY,
            "Exceeds initial supply"
        );

        // Send platform fee to owner
        if (platformFee > 0) {
            IERC20(MEMED_TEST_ETH).transfer(owner(), platformFee);
            emit PlatformFeeCollected(_id, msg.sender, platformFee, "buy");
        }

        Commitment storage commitment = fairLaunch.commitments[msg.sender];
        commitment.amount += ethAfterFee; // Store amount after fee
        commitment.tokenAmount += tokenAmount;

        fairLaunch.totalSold += tokenAmount;
        fairLaunch.totalCommitted += ethAfterFee; // Track committed amount after fee
        fairLaunch.balance[msg.sender] += tokenAmount;

        emit CommitmentMade(_id, msg.sender, _eth);

        // Check if we can launch early
        if (fairLaunch.totalCommitted >= TARGET_ETH_WEI) {
            _completeFairLaunch(_id);
        }
    }

    function _completeFairLaunch(
        uint256 _id
    ) internal {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        require(
            fairLaunch.status == FairLaunchStatus.ACTIVE,
            "Fair launch not launching"
        );
        uint256 s = fairLaunch.totalSold;
        uint256 p = priceAt(s);
        require(p > 0, "price zero");

        uint256 tokenAmount = (TARGET_ETH_WEI * DECIMALS) / p;

        uint256 remaining = TOTAL_FOR_SALE - s;
        if (tokenAmount > remaining) {
            tokenAmount = remaining;
        }

        fairLaunch.status = FairLaunchStatus.COMPLETED;
        // Create Uniswap pair and add liquidity);

        IERC20(MEMED_TEST_ETH).transfer(address(memedFactory), fairLaunch.totalCommitted);
        (address memedToken, address pair) = memedFactory.completeFairLaunch(_id, fairLaunch.totalCommitted, tokenAmount);
        fairLaunch.status = FairLaunchStatus.COMPLETED;
        fairLaunch.uniswapPair = pair;
        tokenIdByAddress[memedToken] = _id;
        emit FairLaunchCompleted(_id, memedToken, pair, fairLaunch.totalCommitted);
    }

    function sellTokens(uint256 _id, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be positive");
        require(
            fairLaunchData[_id].balance[msg.sender] >= _amount,
            "Insufficient token balance"
        );

        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        uint256 ethValue = getTokenToNativeToken(_id, _amount);

        // Calculate platform fee (1%)
        uint256 platformFee = (ethValue * platformFeePercentage) / feeDenominator;
        uint256 ethToUser = ethValue - platformFee;

        require(
            address(this).balance >= ethValue,
            "Insufficient ETH in contract"
        );

        // Send platform fee to owner
        if (platformFee > 0) {
            IERC20(MEMED_TEST_ETH).transfer(owner(), platformFee);
            emit PlatformFeeCollected(_id, msg.sender, platformFee, "sell");
        }

        fairLaunch.balance[msg.sender] -= _amount;
        fairLaunch.totalSold -= _amount;
        fairLaunch.totalCommitted -= ethValue;

        IERC20(MEMED_TEST_ETH).transfer(msg.sender, ethToUser);

        emit TokenSold(_id, msg.sender, _amount, ethToUser);
    }

    function getTokenToNativeToken(
        uint256 _id,
        uint256 _delta
    ) public view returns (uint256 ethValue) {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        uint256 s = fairLaunch.totalSold;
        require(_delta <= s, "delta > s");
        uint256 term1 = 2 * s * _delta;
        uint256 term2 = _delta * _delta;
        uint256 numer = SLOPE * (term1 - term2);
        uint256 denom = 2 * SCALE;
        return numer / denom;
    }

    function getNativeToTokenAmount(
        uint256 _id,
        uint256 _ethAmount
    ) public view returns (uint256 tokenAmount) {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        uint256 s = fairLaunch.totalSold;
        if (_ethAmount == 0) return 0;
        uint256 A = SLOPE;
        uint256 B = 2 * SLOPE * s;
        uint256 B2 = B * B;
        uint256 add = 8 * SLOPE * _ethAmount * SCALE;
        uint256 D = B2 + add;
        uint256 sqrtD = _sqrt(D);
        if (sqrtD <= B) {
            return 0;
        }
        uint256 numer = sqrtD - B;
        uint256 denom = 2 * A;
        return numer / denom;
    }

    function refund(uint256 _id) external nonReentrant {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        require(isRefundable(_id), "Fair launch not failed");
        if (fairLaunch.status != FairLaunchStatus.FAILED) {
            fairLaunch.status = FairLaunchStatus.FAILED;
            uint256 blockExpiry = block.timestamp + 30 days;
            blockedCreators[memedFactory.getTokenById(_id).creator] = blockExpiry; // 30-day block
            emit CreatorBlocked(
                memedFactory.getTokenById(_id).creator,
                blockExpiry,
                "Failed fair launch"
            );
            emit FairLaunchFailed(
                _id,
                fairLaunch.totalCommitted
            );
        }
        Commitment storage commitment = fairLaunch.commitments[msg.sender];
        require(commitment.amount > 0, "No commitment");
        require(!commitment.refunded, "Already refunded");
        IERC20(MEMED_TEST_ETH).transfer(msg.sender, commitment.amount);
        commitment.refunded = true;
    }

    function isRefundable(uint256 _id) public view returns (bool) {
        FairLaunchData storage fairLaunch = fairLaunchData[_id];
        return
            block.timestamp >
            fairLaunch.fairLaunchStartTime + FAIR_LAUNCH_DURATION &&
            fairLaunch.totalCommitted < TARGET_ETH_WEI;
    }

    function getFairLaunchActive(address _token) public view returns (bool) {
        uint256 tokenId = tokenIdByAddress[_token];
        if (tokenId == 0) {
            return false;
        }
        FairLaunchData storage fairLaunch = fairLaunchData[tokenId];
        return fairLaunch.status == FairLaunchStatus.ACTIVE;
    }

    function _tokenExists(address _creator) internal view returns (bool) {
        uint256[] memory tokenIds = tokenIdsByCreator[_creator];
        for (uint i = 0; i < tokenIds.length; i++) {
            if (
                fairLaunchData[tokenIds[i]].status ==
                FairLaunchStatus.COMPLETED ||
                fairLaunchData[tokenIds[i]].status == FairLaunchStatus.ACTIVE
            ) {
                return true;
            }
        }
        return false;
    }

    function getUserCommitment(
        uint256 _id,
        address _user
    ) external view returns (Commitment memory) {
        return fairLaunchData[_id].commitments[_user];
    }

    function isCreatorBlocked(
        address _creator
    ) public view returns (bool blocked, uint256 blockExpiresAt) {
        blockExpiresAt = blockedCreators[_creator];
        blocked = block.timestamp < blockExpiresAt;
        return (blocked, blockExpiresAt);
    }

    function isMintable(address _creator) public view returns (bool) {
        (bool blocked, ) = isCreatorBlocked(_creator);
        return !_tokenExists(_creator) && !blocked;
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

       function priceAt(uint256 s) public pure returns (uint256) {
        return (SLOPE * s) / SCALE;
    }

    function setPlatformFee(
        uint256 _platformFeePercentage,
        uint256 _feeDenominator
    ) external onlyOwner {
        platformFeePercentage = _platformFeePercentage;
        feeDenominator = _feeDenominator;
        emit PlatformFeeSet(_platformFeePercentage, _feeDenominator);
    }

    function setFactory(address _memedFactory) external onlyOwner {
        require(address(memedFactory) == address(0), "Factory already set");
        memedFactory = IMemedFactory_test(_memedFactory);
    }

    // Receive ETH
    receive() external payable {}
}
