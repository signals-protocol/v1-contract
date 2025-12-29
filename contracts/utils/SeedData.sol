// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal data container that stores raw bytes in contract code (SSTORE2-style).
/// @dev Runtime code is exactly `data`, so extcodecopy can read it back efficiently.
contract SeedData {
    constructor(bytes memory data) {
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }
}
