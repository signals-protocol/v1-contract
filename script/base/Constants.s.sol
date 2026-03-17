// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Constants {
    uint256 internal constant DEV_CHAIN_ID = 5115;
    uint256 internal constant PROD_CHAIN_ID = 4114;

    /// @dev ERC1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
}
