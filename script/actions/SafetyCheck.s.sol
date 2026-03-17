// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseScript} from "../base/BaseScript.s.sol";
import {Constants} from "../base/Constants.s.sol";
import {SignalsCore} from "../../contracts/core/SignalsCore.sol";
import {SignalsPosition} from "../../contracts/position/SignalsPosition.sol";
import {SignalsLPShare} from "../../contracts/tokens/SignalsLPShare.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title SafetyCheck — Read-only on-chain state verification
/// @notice Validates deployed contract state matches environment JSON
contract SafetyCheck is BaseScript {
    function run() external view {
        _enforceChainId();

        address coreProxy = _contractAddr("SignalsCoreProxy");
        address positionProxy = _contractAddr("SignalsPositionProxy");

        // LP share proxy: try both keys
        address lpShareProxy = _tryContractAddr("SignalsLPShareProxy");
        if (lpShareProxy == address(0)) {
            lpShareProxy = _contractAddr("SignalsLPShare");
        }

        SignalsCore core = SignalsCore(coreProxy);
        SignalsPosition position = SignalsPosition(positionProxy);
        SignalsLPShare lpShare = SignalsLPShare(lpShareProxy);

        // ── Implementation address checks ───────────────────────────────
        address coreImplExpected = _contractAddr("SignalsCoreImplementation");
        address coreImplActual = address(uint160(uint256(vm.load(coreProxy, Constants.ERC1967_IMPL_SLOT))));
        require(coreImplActual == coreImplExpected, "Core impl mismatch");

        address positionImplExpected = _contractAddr("SignalsPositionImplementation");
        address positionImplActual = address(uint160(uint256(vm.load(positionProxy, Constants.ERC1967_IMPL_SLOT))));
        require(positionImplActual == positionImplExpected, "Position impl mismatch");

        address lpShareImplExpected = _tryContractAddr("SignalsLPShareImplementation");
        if (lpShareImplExpected != address(0)) {
            address lpShareImplActual = address(uint160(uint256(vm.load(lpShareProxy, Constants.ERC1967_IMPL_SLOT))));
            require(lpShareImplActual == lpShareImplExpected, "LPShare impl mismatch");
        }

        // ── Owner checks ────────────────────────────────────────────────
        address expectedCoreOwner = _tryConfigAddr("owners.core");
        if (expectedCoreOwner != address(0)) {
            require(core.owner() == expectedCoreOwner, "Core owner mismatch");
        }
        address expectedPositionOwner = _tryConfigAddr("owners.position");
        if (expectedPositionOwner != address(0)) {
            require(position.owner() == expectedPositionOwner, "Position owner mismatch");
        }
        address expectedLpShareOwner = _tryConfigAddr("owners.lpShare");
        if (expectedLpShareOwner != address(0)) {
            require(lpShare.owner() == expectedLpShareOwner, "LPShare owner mismatch");
        }

        // ── Module checks ───────────────────────────────────────────────
        _assertAddr("TradeModule", core.tradeModule());
        _assertAddr("MarketLifecycleModule", core.lifecycleModule());
        _assertAddr("OracleModule", core.oracleModule());
        _assertAddr("RiskModule", core.riskModule());

        // LPVaultModule: try both keys
        address expectedVault = _tryContractAddr("LPVaultModule");
        if (expectedVault == address(0)) expectedVault = _tryContractAddr("VaultModule");
        if (expectedVault != address(0)) {
            require(core.vaultModule() == expectedVault, "LPVaultModule address mismatch");
        }

        // ── Cross-contract references ───────────────────────────────────
        require(position.core() == address(core), "Position core mismatch");
        require(address(core.positionContract()) == positionProxy, "Core positionContract mismatch");
        require(core.lpShareToken() == lpShareProxy, "Core lpShareToken mismatch");
        require(lpShare.core() == address(core), "LPShare core mismatch");

        // ── Payment token ───────────────────────────────────────────────
        address expectedPayment = _contractAddr("PaymentToken");
        require(address(core.paymentToken()) == expectedPayment, "Payment token mismatch");

        // ── Settlement timeline ─────────────────────────────────────────
        uint256 submitWindow = _tryConfigUint("settlementSubmitWindow");
        if (submitWindow > 0) {
            require(core.settlementSubmitWindow() == submitWindow, "settlementSubmitWindow mismatch");
        }

        uint256 pendingOps = _tryConfigUint("pendingOpsWindow");
        if (pendingOps > 0) {
            require(core.pendingOpsWindow() == pendingOps, "pendingOpsWindow mismatch");
        }

        uint256 claimDelay = _tryConfigUint("settlementFinalizeDeadline");
        if (claimDelay > 0) {
            require(core.claimDelaySeconds() == claimDelay, "claimDelaySeconds mismatch");
        }

        // Invariant: claimDelay == submitWindow + pendingOps
        if (submitWindow > 0 && pendingOps > 0 && claimDelay > 0) {
            require(claimDelay == submitWindow + pendingOps, "claimDelay invariant mismatch");
        }

        // ── Redstone config ─────────────────────────────────────────────
        string memory feedIdStr = _tryConfigString("redstoneFeedId");
        if (bytes(feedIdStr).length > 0) {
            require(core.redstoneFeedId() == _toBytes32(feedIdStr), "redstoneFeedId mismatch");
        }

        uint256 feedDecimals = _tryConfigUint("redstoneFeedDecimals");
        if (feedDecimals > 0) {
            require(core.redstoneFeedDecimals() == feedDecimals, "redstoneFeedDecimals mismatch");
        }

        uint256 maxSampleDist = _tryConfigUint("redstoneMaxSampleDistance");
        if (maxSampleDist > 0) {
            require(core.maxSampleDistance() == maxSampleDist, "maxSampleDistance mismatch");
        }

        uint256 futureTol = _tryConfigUint("redstoneFutureTolerance");
        if (futureTol > 0) {
            require(core.futureTolerance() == futureTol, "futureTolerance mismatch");
        }

        // ── Operator allowlist ──────────────────────────────────────────
        address[] memory operators = _tryConfigAddrArray("operatorAllowlist");
        for (uint256 i = 0; i < operators.length; i++) {
            require(core.operators(operators[i]), "Operator not allowlisted");
        }

        // ── Position sanity ─────────────────────────────────────────────
        require(position.nextId() >= 1, "Position nextId < 1");
        require(keccak256(bytes(position.name())) == keccak256("Signals Position"), "Position name mismatch");

        // ── Code existence checks ───────────────────────────────────────
        _assertCode("SignalsCreate2Factory");
        _assertCode("SignalsDeployer");
        _assertCode("TradeModule");
        _assertCode("MarketLifecycleModule");
        _assertCode("RiskModule");
        _assertCode("LPVaultModule");
        _assertCode("OracleModule");
        _assertCode("FeePolicyNull");
        _assertCode("FeePolicy10bps");
        _assertCode("FeePolicy50bps");
        _assertCode("FeePolicy100bps");
        _assertCode("FeePolicy200bps");
        _assertCode("PaymentToken");
        _assertCode("SignalsLPShareProxy");
        _assertCode("SignalsLPShareImplementation");
        _assertCode("LazyMulSegmentTree");
    }

    // ── Internal helpers ────────────────────────────────────────────────

    function _assertAddr(string memory name, address actual) internal view {
        address expected = _tryContractAddr(name);
        if (expected == address(0)) return;
        require(actual == expected, string.concat(name, " address mismatch"));
    }

    function _assertCode(string memory name) internal view {
        address addr = _tryContractAddr(name);
        if (addr == address(0)) return;
        require(addr.code.length > 0, string.concat(name, " has no code"));
    }
}
