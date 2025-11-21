// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IMemedFactory.sol";
import "../structs/TokenSaleStructs.sol";

/// @title Memed Token Sale Test
/// @notice Test contract for Memed Token Sale
contract MemedTokenSale_test is Ownable, ReentrancyGuard {
    address public constant MEMED_TEST_ETH = 0xc190e6F26cE14e40D30251fDe25927A73a5D58b6;
    uint256 public constant DECIMALS = 1e18;
    uint256 public constant TOTAL_FOR_SALE = 150_000_000 * DECIMALS;
    uint256 public constant RAISE_ETH = 40 ether;
    uint256 public constant LP_ETH = 39.6 ether;
    uint256 public constant PRICE_PER_TOKEN_WEI = 266_666_666_666;
    uint256 public constant FAIR_LAUNCH_DURATION = 20 minutes;
    uint256 public constant FAIR_LAUNCH_COOLDOWN = 20 minutes;

    IMemedFactory public memedFactory;
    uint256 public id;

    mapping(uint256 => FairLaunchData) public fairLaunchData;
    mapping(address => uint256[]) public tokenIdsByCreator;
    mapping(address => uint256) public tokenIdByAddress;
    mapping(address => uint256) public blockedCreators;

    event CommitmentMade(uint256 indexed id, address indexed user, uint256 amount, uint256 tokens);
    event CommitmentCancelled(uint256 indexed id, address indexed user, uint256 amount, uint256 tokens);
    event FairLaunchCompleted(uint256 indexed id, address indexed token, address indexed pair, uint256 totalRaised);
    event FairLaunchFailed(uint256 indexed id, uint256 totalRaised);
    event Claimed(uint256 indexed id, address indexed user, uint256 tokens, uint256 refund);

    constructor() Ownable(msg.sender) {}
    modifier onlyFactory() {
        require(msg.sender == address(memedFactory), "factory only");
        _;
    }

    function setFactory(address _f) external onlyOwner {
        require(address(memedFactory) == address(0), "set");
        memedFactory = IMemedFactory(_f);
    }

    function startFairLaunch(address _creator) external onlyFactory returns (uint256, uint256) {
        if (_creator != address(0)) {
            require(isMintable(_creator), "blocked or exists");
            blockedCreators[_creator] = block.timestamp + FAIR_LAUNCH_COOLDOWN + FAIR_LAUNCH_DURATION;
            tokenIdsByCreator[_creator].push(id);
        }
        id++;
        FairLaunchData storage f = fairLaunchData[id];
        f.status = FairLaunchStatus.ACTIVE;
        f.fairLaunchStartTime = block.timestamp;
        f.createdAt = block.timestamp;
        uint256 endTime = block.timestamp + FAIR_LAUNCH_DURATION;
        return (id, endTime);
    }

    function commitToFairLaunch(uint256 _id, uint256 amount) external nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.ACTIVE, "inactive");
        require(block.timestamp <= f.fairLaunchStartTime + FAIR_LAUNCH_DURATION, "ended");
        require(amount > 0, "zero");
        IERC20(MEMED_TEST_ETH).transferFrom(msg.sender, address(this), amount);
        Commitment storage c = f.commitments[msg.sender];
        c.amount += amount;
        f.totalCommitted += amount;
        emit CommitmentMade(_id, msg.sender, amount, 0);
    }

    function cancelCommit(uint256 _id) external nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.ACTIVE, "state");
        require(block.timestamp <= f.fairLaunchStartTime + FAIR_LAUNCH_DURATION, "ended");
        Commitment storage c = f.commitments[msg.sender];
        require(c.amount > 0, "none");
        uint256 amt = c.amount;
        c.amount = 0;
        f.totalCommitted -= amt;
        IERC20(MEMED_TEST_ETH).transfer(msg.sender, amt);
        emit CommitmentCancelled(_id, msg.sender, amt, 0);
    }

    function finalizeSale(uint256 _id) external nonReentrant onlyFactory {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.ACTIVE, "state");
        require(block.timestamp > f.fairLaunchStartTime + FAIR_LAUNCH_DURATION, "not ended");
        require(f.totalCommitted >= RAISE_ETH, "min not reached");
        uint256 ethForAllocation = f.totalCommitted > RAISE_ETH ? RAISE_ETH : f.totalCommitted;
        f.totalSold = TOTAL_FOR_SALE;
        uint256 fee = ethForAllocation - LP_ETH;
        IERC20(MEMED_TEST_ETH).transfer(owner(), fee);
        IERC20(MEMED_TEST_ETH).transfer(address(memedFactory), LP_ETH);
    }

    function completeFairLaunch(uint256 _id, address _token, address _pair) external onlyFactory {
        FairLaunchData storage f = fairLaunchData[_id];
        f.status = FairLaunchStatus.COMPLETED;
        f.uniswapPair = _pair;
        tokenIdByAddress[_token] = _id;
        emit FairLaunchCompleted(_id, _token, _pair, f.totalCommitted);
    }

    function refund(uint256 _id) external nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(isRefundable(_id), "no");
        if (f.status != FairLaunchStatus.FAILED) {
            f.status = FairLaunchStatus.FAILED;
            emit FairLaunchFailed(_id, f.totalCommitted);
        }
        Commitment storage c = f.commitments[msg.sender];
        require(c.amount > 0 && !c.refunded, "none");
        c.refunded = true;
        IERC20(MEMED_TEST_ETH).transfer(msg.sender, c.amount);
    }

    function claim(uint256 _id) external nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.COMPLETED, "incomplete");
        Commitment storage c = f.commitments[msg.sender];
        require(c.amount > 0 && !c.claimed, "none");
        uint256 userTokens;
        if (f.totalCommitted >= RAISE_ETH) {
            userTokens = (c.amount * TOTAL_FOR_SALE) / f.totalCommitted;
        } else {
            userTokens = (c.amount * DECIMALS) / PRICE_PER_TOKEN_WEI;
        }
        c.claimed = true;
        c.tokenAmount = userTokens;
        f.balance[msg.sender] = userTokens;
        IERC20(memedFactory.getTokenById(_id).token).transfer(msg.sender, userTokens);
        uint256 refundAmount = 0;
        if (f.totalCommitted > RAISE_ETH && !c.refunded) {
            uint256 ethUsed = (c.amount * RAISE_ETH) / f.totalCommitted;
            refundAmount = c.amount - ethUsed;
            c.refunded = true;
            IERC20(MEMED_TEST_ETH).transfer(msg.sender, refundAmount);
        }
        emit Claimed(_id, msg.sender, userTokens, refundAmount);
    }

    function getFairLaunchStatus(uint256 _id) public view returns (FairLaunchStatus) {
        return fairLaunchData[_id].status;
    }

    function getUserCommitment(uint256 _id, address u) external view returns (Commitment memory) {
        return fairLaunchData[_id].commitments[u];
    }

    function isRefundable(uint256 _id) public view returns (bool) {
        FairLaunchData storage f = fairLaunchData[_id];
        return (f.status == FairLaunchStatus.FAILED || f.status == FairLaunchStatus.ACTIVE) &&
            block.timestamp > f.fairLaunchStartTime + FAIR_LAUNCH_DURATION &&
            f.totalCommitted < RAISE_ETH;
    }

    function getFairLaunchActive(address _t) public view returns (bool) {
        uint256 tid = tokenIdByAddress[_t];
        if (tid == 0) return false;
        return fairLaunchData[tid].status == FairLaunchStatus.ACTIVE;
    }

    function _tokenExists(address _c) internal view returns (bool) {
        uint256[] memory ids = tokenIdsByCreator[_c];
        for (uint i = 0; i < ids.length; i++) {
            FairLaunchStatus s = fairLaunchData[ids[i]].status;
            if (s == FairLaunchStatus.COMPLETED || (s == FairLaunchStatus.ACTIVE && !isRefundable(ids[i]))) return true;
        }
        return false;
    }

    function isCreatorBlocked(address _c) public view returns (bool, uint256) {
        uint256 e = blockedCreators[_c];
        return (block.timestamp < e, e);
    }

    function isMintable(address _c) public view returns (bool) {
        (bool b, ) = isCreatorBlocked(_c);
        return !_tokenExists(_c) && !b;
    }

    function isCompletable(uint256 _id) public view returns (bool) {
        FairLaunchData storage f = fairLaunchData[_id];
        return f.status == FairLaunchStatus.ACTIVE && block.timestamp > f.fairLaunchStartTime + FAIR_LAUNCH_DURATION && f.totalCommitted >= RAISE_ETH;
    }

    function getExpectedClaim(uint256 _id, address user) public view returns (uint256 tokens, uint256 refundAmount) {
        FairLaunchData storage f = fairLaunchData[_id];
        Commitment storage c = f.commitments[user];
        if (c.amount == 0) return (0, 0);
        if (f.totalCommitted >= RAISE_ETH) {
            tokens = (c.amount * TOTAL_FOR_SALE) / f.totalCommitted;
            if (f.totalCommitted > RAISE_ETH && !c.refunded) {
                uint256 ethUsed = (c.amount * RAISE_ETH) / f.totalCommitted;
                refundAmount = c.amount - ethUsed;
            }
        } else {
            tokens = (c.amount * DECIMALS) / PRICE_PER_TOKEN_WEI;
            refundAmount = 0;
        }
    }

    function quoteNetForTokens(uint256 tokenAmount) public pure returns (uint256) {
        return (tokenAmount * PRICE_PER_TOKEN_WEI) / DECIMALS;
    }
}