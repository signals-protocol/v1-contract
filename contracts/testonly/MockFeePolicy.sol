// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IFeePolicy.sol";

/// @notice Mock fee policy returning a fixed basis-point fee over baseAmount.
contract MockFeePolicy is IFeePolicy {
    uint256 public bps; // e.g., 100 = 1%

    constructor(uint256 _bps) {
        bps = _bps;
    }

    function quoteFee(QuoteParams calldata params) external view returns (uint256 feeAmount) {
        feeAmount = (params.baseAmount * bps) / 10_000;
    }

    function name() external pure returns (string memory) {
        return "MockFeePolicy";
    }

    function descriptor() external pure returns (string memory) {
        return "{\"policy\":\"mock-bps\"}";
    }
}
