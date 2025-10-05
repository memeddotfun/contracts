// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMemedFactory {
    struct TokenData {
        address token;
        address warriorNFT;
        address creator;
        bool isClaimedByCreator;
        string name;
        string ticker;
        string description;
        string image;
        string lensUsername;
        uint256 lastRewardAt;
        uint256 createdAt;
    }
    
    function getByToken(address _token) external view returns (TokenData memory);
    function updateHeat(address _token, uint256 _heat) external;
    function swap(uint256 _amount, address[] calldata _path, address _to) external returns (uint[] memory amounts);
    function getTokenById(uint256 _id) external view returns (TokenData memory);
    function getHeat(address _token) external view returns (uint256);
    function getWarriorNFT(address _token) external view returns (address);
    function getMemedEngageToEarn() external view returns (address);
    function getTokenId(address _token) external view returns (uint256);
    function getMemedBattle() external view returns (address);
    function completeFairLaunch(uint256 _id, uint256 _tokenAmount, uint256 _tokenBAmount) external returns (address, address);
    function owner() external view returns (address);
    function battleUpdate(address _winner, address _loser) external;
    function getCreatorById(uint256 _id) external view returns (address);
}
