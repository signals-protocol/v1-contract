// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../../contracts/utils/SeedData.sol";

/// @title SeedHelper
/// @notice Packs factor arrays and deploys SeedData contracts for test market creation.
library SeedHelper {
    /// @notice ABI-encode factors as packed uint256[] (matches ethers.solidityPacked)
    function packFactors(uint256[] memory factors) internal pure returns (bytes memory packed) {
        packed = new bytes(factors.length * 32);
        for (uint256 i = 0; i < factors.length; i++) {
            uint256 f = factors[i];
            uint256 offset = i * 32;
            assembly ("memory-safe") {
                mstore(add(add(packed, 32), offset), f)
            }
        }
    }

    /// @notice Deploy a SeedData contract containing the packed factors
    function deploySeedData(uint256[] memory factors) internal returns (SeedData) {
        return new SeedData(packFactors(factors));
    }
}
