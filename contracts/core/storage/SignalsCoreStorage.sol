// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/ISignalsCore.sol";
import "../../interfaces/ISignalsPosition.sol";
import "../../lib/LazyMulSegmentTree.sol";

abstract contract SignalsCoreStorage {
    // Governance-configurable settlement windows (set via initializer/setter in Core).
    uint64 public settlementSubmitWindow;
    uint64 public settlementFinalizeDeadline;

    IERC20 public paymentToken;
    ISignalsPosition public positionContract;

    mapping(uint256 => ISignalsCore.Market) public markets;
    mapping(uint256 => LazyMulSegmentTree.Tree) public marketTrees;
    uint256 public nextMarketId;

    struct SettlementOracleState {
        int256 candidateValue;
        uint64 candidatePriceTimestamp;
    }

    mapping(uint256 => SettlementOracleState) internal settlementOracleState;
    address public settlementOracleSigner;

    address public feeRecipient;
    address public defaultFeePolicy;

    // Reserve ample slots for future upgrades; do not change after first deployment.
    uint256[51] internal __gap;
}
