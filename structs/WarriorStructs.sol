// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

struct WarriorData {
    uint256 tokenId;
    address owner;
    uint256 mintPrice;
    uint256 mintedAt;
    bool allocated;
}
