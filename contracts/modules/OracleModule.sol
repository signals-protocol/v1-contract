// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../errors/ModuleErrors.sol";
import "../errors/CLMSRErrors.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Delegate-only oracle module (skeleton)
contract OracleModule is SignalsCoreStorage {
    address private immutable self;

    modifier onlyDelegated() {
        if (address(this) == self) revert ModuleErrors.NotDelegated();
        _;
    }

    constructor() {
        self = address(this);
    }

    event SettlementPriceSubmitted(
        uint256 indexed marketId,
        int256 settlementValue,
        uint64 priceTimestamp,
        address indexed signer
    );

    function setOracleConfig(address signer) external onlyDelegated {
        if (signer == address(0)) revert CE.ZeroAddress();
        settlementOracleSigner = signer;
    }

    function submitSettlementPrice(
        uint256 marketId,
        int256 settlementValue,
        uint64 priceTimestamp,
        bytes calldata signature
    ) external onlyDelegated {
        ISignalsCore.Market storage market = markets[marketId];
        if (market.numBins == 0) revert CE.MarketNotFound(marketId);
        if (market.settled) revert CE.MarketAlreadySettled(marketId);

        uint64 endTs = market.endTimestamp;
        if (priceTimestamp < endTs) revert CE.SettlementTooEarly(endTs, priceTimestamp);
        if (priceTimestamp > endTs + settlementSubmitWindow) {
            revert CE.SettlementFinalizeWindowClosed(endTs + settlementSubmitWindow, priceTimestamp);
        }
        if (priceTimestamp > block.timestamp) {
            revert CE.SettlementTooEarly(priceTimestamp, uint64(block.timestamp));
        }

        address recovered = _recoverSigner(marketId, settlementValue, priceTimestamp, signature);
        if (recovered != settlementOracleSigner) {
            revert CE.SettlementOracleSignatureInvalid(recovered);
        }

        settlementOracleState[marketId] = SettlementOracleState({
            candidateValue: settlementValue,
            candidatePriceTimestamp: priceTimestamp
        });
        emit SettlementPriceSubmitted(marketId, settlementValue, priceTimestamp, recovered);
    }

    function getSettlementPrice(uint256 marketId, uint256 /*timestamp*/)
        external
        view
        returns (int256 price, uint64 priceTimestamp)
    {
        SettlementOracleState storage state = settlementOracleState[marketId];
        if (state.candidatePriceTimestamp == 0) revert CE.SettlementOracleCandidateMissing();
        price = state.candidateValue;
        priceTimestamp = state.candidatePriceTimestamp;
    }

    function _recoverSigner(
        uint256 marketId,
        int256 settlementValue,
        uint64 priceTimestamp,
        bytes calldata signature
    ) internal view returns (address) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(block.chainid, address(this), marketId, settlementValue, priceTimestamp))
        );
        return ECDSA.recover(digest, signature);
    }
}
