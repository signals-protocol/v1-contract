// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/ISignalsCore.sol";
import "../lib/OracleTickLib.sol";

contract OracleTickLibHarness {
    mapping(uint256 => ISignalsCore.Market) internal markets;

    function setMarket(ISignalsCore.Market calldata market) external {
        markets[1] = market;
    }

    function toSettlementTick(int256 settlementValue) external view returns (int256) {
        return OracleTickLib.toSettlementTick(markets[1], settlementValue);
    }
}
