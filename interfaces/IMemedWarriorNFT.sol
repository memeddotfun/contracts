// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

/// @title IMemedWarriorNFT
/// @notice Interface for the Memed Warrior NFT contract
interface IMemedWarriorNFT {
    function hasActiveWarrior(address user) external view returns (bool);
    function getUserActiveNFTs(
        address user
    ) external view returns (uint256[] memory);
    function getCurrentPrice() external view returns (uint256);
    function getWarriorMintedBeforeByUser(
        address _user,
        uint256 _timestamp
    ) external view returns (uint256[] memory);
    function memedToken() external view returns (address);
    function currentTokenId() external view returns (uint256);
    function allocateNFTsToBattle(
        address _user,
        uint256[] calldata _nftsIds
    ) external;
}
