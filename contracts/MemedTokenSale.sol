// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IMemedFactory.sol";
import "../structs/TokenSaleStructs.sol";

contract MemedTokenSale is Ownable, ReentrancyGuard {
    uint256 public constant DECIMALS = 1e18;
    uint256 public constant TOTAL_FOR_SALE = 150_000_000 * DECIMALS;
    uint256 public constant RAISE_ETH = 40 ether;
    uint256 public constant LP_ETH = 39.6 ether;
    uint256 public constant PRICE_PER_TOKEN_WEI = 266_666_666_666;
    uint256 public constant FAIR_LAUNCH_DURATION = 30 days; // 30 days fair launch duration
    uint256 public constant FAIR_LAUNCH_COOLDOWN = 30 days; // 30 days fair launch cooldown
    IMemedFactory public memedFactory;
    uint256 public id;

    mapping(uint256 => FairLaunchData) public fairLaunchData;
    mapping(address => uint256[]) public tokenIdsByCreator;
    mapping(address => uint256) public tokenIdByAddress;
    mapping(address => uint256) public blockedCreators;

    event FairLaunchStarted(
        uint256 indexed id,
        address indexed creator,
        uint256 start,
        uint256 end
    );
    event CommitmentMade(
        uint256 indexed id,
        address indexed user,
        uint256 amount,
        uint256 tokens
    );
    event CommitmentCancelled(
        uint256 indexed id,
        address indexed user,
        uint256 amount,
        uint256 tokens
    );
    event FairLaunchReadyToComplete(uint256 indexed id);
    event FairLaunchCompleted(
        uint256 indexed id,
        address indexed token,
        address indexed pair,
        uint256 totalRaised
    );
    event FairLaunchFailed(uint256 indexed id, uint256 totalRaised);

    constructor() Ownable(msg.sender) {}
    modifier onlyFactory() {
        require(msg.sender == address(memedFactory), "factory only");
        _;
    }

    receive() external payable {}

    function setFactory(address _f) external onlyOwner {
        require(address(memedFactory) == address(0), "set");
        memedFactory = IMemedFactory(_f);
    }

    function startFairLaunch(address _creator) external returns (uint256) {
        if (_creator != address(0))
            require(isMintable(_creator), "blocked or exists");
        require(msg.sender == address(memedFactory), "factory only");
        id++;
        FairLaunchData storage f = fairLaunchData[id];
        f.status = FairLaunchStatus.ACTIVE;
        f.fairLaunchStartTime = block.timestamp;
        f.createdAt = block.timestamp;
        tokenIdsByCreator[_creator].push(id);
        blockedCreators[_creator] =
            block.timestamp +
            FAIR_LAUNCH_COOLDOWN +
            FAIR_LAUNCH_DURATION;
        emit FairLaunchStarted(
            id,
            _creator,
            block.timestamp,
            block.timestamp + FAIR_LAUNCH_DURATION
        );
        return id;
    }

    function commitToFairLaunch(uint256 _id) external payable nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.ACTIVE, "inactive");
        require(
            block.timestamp <= f.fairLaunchStartTime + FAIR_LAUNCH_DURATION,
            "ended"
        );
        require(msg.value > 0, "zero");

        uint256 capLeft = RAISE_ETH - f.totalCommitted;
        require(capLeft > 0, "cap");
        uint256 useAmount = msg.value > capLeft ? capLeft : msg.value;
        uint256 tokensOut = (useAmount * DECIMALS) / PRICE_PER_TOKEN_WEI;
        uint256 remaining = TOTAL_FOR_SALE - f.totalSold;
        if (tokensOut > remaining) {
            tokensOut = remaining;
            useAmount = (tokensOut * PRICE_PER_TOKEN_WEI) / DECIMALS;
        }
        uint256 refundAmount = msg.value > useAmount
            ? msg.value - useAmount
            : 0;
        if (refundAmount > 0) {
            (bool okr, ) = payable(msg.sender).call{value: refundAmount}("");
            require(okr, "refund");
        }

        Commitment storage c = f.commitments[msg.sender];
        c.amount += useAmount;
        c.tokenAmount += tokensOut;
        f.totalSold += tokensOut;
        f.totalCommitted += useAmount;
        f.balance[msg.sender] += tokensOut;

        emit CommitmentMade(_id, msg.sender, useAmount, tokensOut);

        if (f.totalSold == TOTAL_FOR_SALE) _completeFairLaunch(_id);
    }

    function cancelCommit(uint256 _id) external nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.ACTIVE, "state");
        Commitment storage c = f.commitments[msg.sender];
        require(c.amount > 0 || c.tokenAmount > 0, "none");
        uint256 amt = c.amount;
        uint256 tok = c.tokenAmount;
        c.amount = 0;
        c.tokenAmount = 0;
        f.totalCommitted -= amt;
        f.totalSold -= tok;
        f.balance[msg.sender] -= tok;
        (bool ok, ) = payable(msg.sender).call{value: amt}("");
        require(ok, "xfer");
        emit CommitmentCancelled(_id, msg.sender, amt, tok);
    }

    function _completeFairLaunch(uint256 _id) internal {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.ACTIVE, "state");
        require(f.totalSold == TOTAL_FOR_SALE, "!=150M");
        uint256 fee = f.totalCommitted - LP_ETH;
        (bool ok1, ) = payable(owner()).call{value: fee}("");
        require(ok1, "fee");
        (bool ok2, ) = payable(address(memedFactory)).call{value: LP_ETH}("");
        require(ok2, "xfer");
        f.status = FairLaunchStatus.READY_TO_COMPLETE;
        emit FairLaunchReadyToComplete(_id);
    }

    function completeFairLaunch(
        uint256 _id,
        address _token,
        address _pair
    ) external onlyFactory {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.READY_TO_COMPLETE, "not ready");
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
        (bool ok, ) = payable(msg.sender).call{value: c.amount}("");
        require(ok, "xfer");
    }

    function claim(uint256 _id) external nonReentrant {
        FairLaunchData storage f = fairLaunchData[_id];
        require(f.status == FairLaunchStatus.COMPLETED, "incomplete");
        Commitment storage c = f.commitments[msg.sender];
        require(c.tokenAmount > 0 && !c.claimed, "none");
        c.claimed = true;
        IERC20(memedFactory.getTokenById(_id).token).transfer(
            msg.sender,
            c.tokenAmount
        );
    }

    function getFairLaunchStatus(
        uint256 _id
    ) public view returns (FairLaunchStatus) {
        FairLaunchData storage f = fairLaunchData[_id];
        return f.status;
    }
    function getUserCommitment(
        uint256 _id,
        address u
    ) external view returns (Commitment memory) {
        return fairLaunchData[_id].commitments[u];
    }
    function isRefundable(uint256 _id) public view returns (bool) {
        FairLaunchData storage f = fairLaunchData[_id];
        return
            (f.status == FairLaunchStatus.FAILED ||
                f.status == FairLaunchStatus.ACTIVE) &&
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
            if (s == FairLaunchStatus.COMPLETED || s == FairLaunchStatus.ACTIVE)
                return true;
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

    function getMaxCommittableETH(uint256 _id) public view returns (uint256) {
        FairLaunchData storage f = fairLaunchData[_id];
        if (
            f.status != FairLaunchStatus.ACTIVE ||
            f.totalCommitted >= RAISE_ETH ||
            f.totalSold >= TOTAL_FOR_SALE
        ) return 0;
        return RAISE_ETH - f.totalCommitted;
    }
    function quoteNetForTokens(uint256 tokens) public pure returns (uint256) {
        return (tokens * PRICE_PER_TOKEN_WEI) / DECIMALS;
    }
}
