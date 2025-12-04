// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IFeePolicy.sol";

/// @notice Fee policy that deliberately overcharges (>100% of base) for testing revert paths.
contract MockExcessiveFeePolicy is IFeePolicy {
    function quoteFee(QuoteParams calldata params) external pure returns (uint256 feeAmount) {
        // charge 200% of base to trigger FeeExceedsBase
        feeAmount = params.baseAmount * 2;
    }

    function name() external pure returns (string memory) {
        return "MockExcessiveFeePolicy";
    }

    function descriptor() external pure returns (string memory) {
        return "{\"policy\":\"excessive\"}";
    }
}
