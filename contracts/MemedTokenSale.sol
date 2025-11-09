// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IMemedFactory.sol";
import "../structs/TokenSaleStructs.sol";

contract MemedTokenSale is Ownable, ReentrancyGuard {
    uint256 public constant FAIR_LAUNCH_DURATION = 30 days;
    uint256 public constant DECIMALS = 1e18;
    uint256 public constant TOTAL_FOR_SALE = 200_000_000 * DECIMALS;
    uint256 public constant TARGET_ETH_WEI = 40 ether;
    uint256 public constant SCALE = 1e18;
    uint256 public constant SLOPE = 2000;

    uint256 public platformFeePercentage = 10;
    uint256 public feeDenominator = 1000;
    IMemedFactory public memedFactory;

    uint256 public id;

    mapping(uint256 => FairLaunchData) public fairLaunchData;
    mapping(address => uint256[]) public tokenIdsByCreator;
    mapping(address => uint256) public tokenIdByAddress;
    mapping(address => uint256) public blockedCreators;

    event FairLaunchStarted(uint256 indexed id, address indexed creator, uint256 startTime, uint256 endTime);
    event CommitmentMade(uint256 indexed id, address indexed user, uint256 amount);
    event FairLaunchReadyToComplete(uint256 indexed id);
    event FairLaunchCompleted(uint256 indexed id, address indexed token, address indexed warriorNFT, uint256 totalRaised);
    event FairLaunchFailed(uint256 indexed id, uint256 totalRaised);
    event LiquidityAdded(uint256 indexed id, address indexed pair, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity);
    event CreatorBlocked(address indexed creator, uint256 blockExpiresAt, string reason);
    event TokenSold(uint256 indexed id, address indexed seller, uint256 tokenAmount, uint256 ethReceived);
    event TokensClaimed(uint256 indexed id, address indexed user, uint256 tokenAmount);
    event PlatformFeeCollected(uint256 indexed id, address indexed user, uint256 feeAmount, string transactionType);
    event PlatformFeeSet(uint256 platformFeePercentage, uint256 feeDenominator);

    constructor() Ownable(msg.sender) {}

    modifier onlyFactory() { require(msg.sender == address(memedFactory), "Only factory"); _; }

    function startFairLaunch(address _creator) external returns (uint256) {
        if (_creator != address(0)) require(isMintable(_creator), "Not mintable");
        require(msg.sender == address(memedFactory), "Only factory");
        id++;
        FairLaunchData storage f = fairLaunchData[id];
        f.status = FairLaunchStatus.ACTIVE;
        f.fairLaunchStartTime = block.timestamp;
        f.createdAt = block.timestamp;
        tokenIdsByCreator[_creator].push(id);
        emit FairLaunchStarted(id, _creator, block.timestamp, block.timestamp + FAIR_LAUNCH_DURATION);
        return id;
    }

    function commitToFairLaunch(uint256 _id) external payable nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.ACTIVE, "Inactive");
        require(block.timestamp <= f.fairLaunchStartTime + FAIR_LAUNCH_DURATION, "Ended");
        require(msg.value > 0, "Zero");
        uint256 fee = (msg.value * platformFeePercentage) / feeDenominator;
        uint256 net = msg.value - fee;
        uint256 tokens = getNativeToTokenAmount(f.totalSold, net);
        require(tokens > 0, "Insufficient");
        require(f.totalSold + tokens <= TOTAL_FOR_SALE, "Sold out");
        if (fee > 0) { (bool fs,) = payable(owner()).call{value: fee}(""); require(fs, "Fee xfer"); emit PlatformFeeCollected(_id, msg.sender, fee, "buy"); }
        Commitment storage c = f.commitments[msg.sender];
        c.amount += net;
        c.tokenAmount += tokens;
        f.totalSold += tokens;
        f.totalCommitted += net;
        f.balance[msg.sender] += tokens;
        emit CommitmentMade(_id, msg.sender, msg.value);
        if (f.totalCommitted >= TARGET_ETH_WEI) _completeFairLaunch(_id);
    }

    function _completeFairLaunch(uint256 _id) internal {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.ACTIVE, "Not launching");
        require(f.totalCommitted >= TARGET_ETH_WEI, "Target");
        (bool ok,) = payable(address(memedFactory)).call{value: f.totalCommitted}("");
        require(ok, "Transfer");
        f.status = FairLaunchStatus.READY_TO_COMPLETE;
        emit FairLaunchReadyToComplete(_id);
    }

    function completeFairLaunch(uint256 _id, address _token, address _pair) external onlyFactory {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.READY_TO_COMPLETE, "Not ready");
        f.status = FairLaunchStatus.COMPLETED;
        f.uniswapPair = _pair;
        tokenIdByAddress[_token] = _id;
        emit FairLaunchCompleted(_id, _token, _pair, f.totalCommitted);
    }

    function sellTokens(uint256 _id, uint256 _amount) external nonReentrant {
        require(_amount > 0, "Zero");
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.balance[msg.sender] >= _amount, "Balance");
        uint256 ethValue = sellQuoteEthForTokens(f.totalSold, _amount);
        uint256 fee = (ethValue * platformFeePercentage) / feeDenominator;
        uint256 toUser = ethValue - fee;
        require(address(this).balance >= ethValue, "Treasury");
        if (fee > 0) { (bool fs,) = payable(owner()).call{value: fee}(""); require(fs, "Fee xfer"); emit PlatformFeeCollected(_id, msg.sender, fee, "sell"); }
        f.balance[msg.sender] -= _amount;
        f.totalSold -= _amount;
        f.totalCommitted -= ethValue;
        (bool ok,) = payable(msg.sender).call{value: toUser}("");
        require(ok, "Transfer");
        emit TokenSold(_id, msg.sender, _amount, toUser);
    }

    function refund(uint256 _id) external nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(isRefundable(_id), "Not refundable");
        if (f.status != FairLaunchStatus.FAILED) {
            f.status = FairLaunchStatus.FAILED;
            uint256 blockExpiry = block.timestamp + 30 days;
            blockedCreators[memedFactory.getCreatorById(_id)] = blockExpiry;
            emit CreatorBlocked(memedFactory.getCreatorById(_id), blockExpiry, "Failed fair launch");
            emit FairLaunchFailed(_id, f.totalCommitted);
        }
        Commitment storage c = f.commitments[msg.sender];
        require(c.amount > 0, "No commit");
        require(!c.refunded, "Refunded");
        (bool ok,) = payable(msg.sender).call{value: c.amount}("");
        require(ok, "Transfer");
        c.refunded = true;
    }

    function claim(uint256 _id) external nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.COMPLETED, "Not completed");
        Commitment storage c = f.commitments[msg.sender];
        require(c.tokenAmount > 0, "None");
        require(!c.claimed, "Claimed");
        c.claimed = true;
        IERC20(memedFactory.getTokenById(_id).token).transfer(msg.sender, c.tokenAmount);
        emit TokensClaimed(_id, msg.sender, c.tokenAmount);
    }

    function isRefundable(uint256 _id) public view returns (bool) {
        FairLaunchData storage f = fairLaunchData[_id];
        return block.timestamp > f.fairLaunchStartTime + FAIR_LAUNCH_DURATION && f.totalCommitted < TARGET_ETH_WEI;
    }

    function getFairLaunchActive(address _token) public view returns (bool) {
        uint256 tokenId = tokenIdByAddress[_token];
        if (tokenId == 0) return false;
        FairLaunchData storage f = fairLaunchData[tokenId];
        return f.status == FairLaunchStatus.ACTIVE;
    }

    function getFairLaunchData(uint256 _id) public view returns (FairLaunchStatus, uint256) {
        FairLaunchData storage f = fairLaunchData[_id];
        return (f.status, f.totalCommitted);
    }

    function _tokenExists(address _creator) internal view returns (bool) {
        uint256[] memory ids = tokenIdsByCreator[_creator];
        for (uint256 i = 0; i < ids.length; i++) {
            if (fairLaunchData[ids[i]].status == FairLaunchStatus.COMPLETED || fairLaunchData[ids[i]].status == FairLaunchStatus.ACTIVE) return true;
        }
        return false;
    }

    function getUserCommitment(uint256 _id, address _user) external view returns (Commitment memory) {
        return fairLaunchData[_id].commitments[_user];
    }

    function isCreatorBlocked(address _creator) public view returns (bool blocked, uint256 blockExpiresAt) {
        blockExpiresAt = blockedCreators[_creator];
        blocked = block.timestamp < blockExpiresAt;
        return (blocked, blockExpiresAt);
    }

    function isMintable(address _creator) public view returns (bool) {
        (bool blocked,) = isCreatorBlocked(_creator);
        return !_tokenExists(_creator) && !blocked;
    }

    function priceAt(uint256 s) public pure returns (uint256) {
        return (SLOPE * s) / (SCALE * DECIMALS);
    }

    function getNativeToTokenAmount(uint256 s, uint256 eth) public pure returns (uint256) {
        uint256 term = (2 * eth * SCALE * DECIMALS) / SLOPE;
        uint256 sum = s * s + term;
        uint256 root = _sqrt(sum);
        require(root >= s, "sqrt");
        return root - s;
    }

    function buyQuoteEthForTokens(uint256 s, uint256 delta) public pure returns (uint256) {
        uint256 twoSplusD = (s << 1) + delta;
        uint256 product = delta * twoSplusD;
        return (SLOPE * product) / (2 * SCALE * DECIMALS);
    }

    function sellQuoteEthForTokens(uint256 s, uint256 delta) public pure returns (uint256) {
        require(delta <= s, "delta>s");
        uint256 twoSminusD = (s << 1) - delta;
        uint256 product = delta * twoSminusD;
        return (SLOPE * product) / (2 * SCALE * DECIMALS);
    }

    function getMaxCommittableETH(uint256 _id) public view returns (uint256) {
        FairLaunchData storage f = fairLaunchData[_id];
        if (f.status != FairLaunchStatus.ACTIVE) return 0;
        if (f.totalCommitted >= TARGET_ETH_WEI) return 0;
        if (f.totalSold >= TOTAL_FOR_SALE) return 0;
        uint256 remainingToTarget = TARGET_ETH_WEI - f.totalCommitted;
        uint256 remainingTokens = TOTAL_FOR_SALE - f.totalSold;
        uint256 ethForAllTokens = buyQuoteEthForTokens(f.totalSold, remainingTokens);
        uint256 maxNet = remainingToTarget < ethForAllTokens ? remainingToTarget : ethForAllTokens;
        return (maxNet * feeDenominator) / (feeDenominator - platformFeePercentage);
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
        return y;
    }

    function setPlatformFee(uint256 _platformFeePercentage, uint256 _feeDenominator) external onlyOwner {
        platformFeePercentage = _platformFeePercentage;
        feeDenominator = _feeDenominator;
        emit PlatformFeeSet(_platformFeePercentage, _feeDenominator);
    }

    function setFactory(address _memedFactory) external onlyOwner {
        require(address(memedFactory) == address(0), "Factory set");
        memedFactory = IMemedFactory(_memedFactory);
    }

    receive() external payable {}
}
