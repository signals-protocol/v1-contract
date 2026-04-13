// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IFeePolicy.sol";

contract MockTraderFeePolicy is IFeePolicy {
    address public immutable expectedTrader;
    uint256 public immutable expectedFee;
    uint256 public immutable fallbackFee;

    constructor(address expectedTrader_, uint256 expectedFee_, uint256 fallbackFee_) {
        expectedTrader = expectedTrader_;
        expectedFee = expectedFee_;
        fallbackFee = fallbackFee_;
    }

    function quoteFee(QuoteParams calldata params) external view returns (uint256 feeAmount) {
        feeAmount = params.trader == expectedTrader ? expectedFee : fallbackFee;
    }

    function name() external pure returns (string memory) {
        return "MockTraderFeePolicy";
    }

    function descriptor() external pure returns (string memory) {
        return '{"policy":"trader","name":"MockTraderFeePolicy"}';
    }
}
