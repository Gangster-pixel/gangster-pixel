// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// External dependency: the SPACE ID .ai Agent ID registry (ERC721-style; balanceOf > 0 means the address is an agent)
interface IAgentIdRegistry {
    function balanceOf(address owner) external view returns (uint256);
}
