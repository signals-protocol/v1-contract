// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal error set from v0 used by math/tree libraries.
interface CLMSRErrors {
    /* Trade / math */
    error MathMulOverflow();
    error NonIncreasingSum(uint256 beforeSum, uint256 afterSum);
    error SumAfterZero();
    error NoChunkProgress();
    error ResidualQuantity(uint256 remaining);
    error AffectedSumZero();
    error ChunkLimitExceeded(uint256 required, uint256 maxAllowed);

    /* Tree */
    error TreeNotInitialized();
    error TreeSizeZero();
    error TreeSizeTooLarge();
    error TreeAlreadyInitialized();
    error LazyFactorOverflow();
    error ArrayLengthMismatch();
    error InvalidFactor(uint256 factor);
    error IndexOutOfBounds(uint32 index, uint32 size);
    error InvalidRange(uint32 lo, uint32 hi);
}

/// @notice Alias for ease of import parity with v0.
library CE {
    /* Trade / math */
    error MathMulOverflow();
    error NonIncreasingSum(uint256 beforeSum, uint256 afterSum);
    error SumAfterZero();
    error NoChunkProgress();
    error ResidualQuantity(uint256 remaining);
    error AffectedSumZero();
    error ChunkLimitExceeded(uint256 required, uint256 maxAllowed);

    /* Tree */
    error TreeNotInitialized();
    error TreeSizeZero();
    error TreeSizeTooLarge();
    error TreeAlreadyInitialized();
    error LazyFactorOverflow();
    error ArrayLengthMismatch();
    error InvalidFactor(uint256 factor);
    error IndexOutOfBounds(uint32 index, uint32 size);
    error InvalidRange(uint32 lo, uint32 hi);
}
