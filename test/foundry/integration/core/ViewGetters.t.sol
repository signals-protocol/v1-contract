// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title ViewGetters Integration Tests
/// @notice Tests for FE-facing view functions (22 tests from viewGetters.spec.ts)
contract ViewGettersTest is FullSystemDeployer {
    FullSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();
    }

    // ============================================================
    // Vault view getters
    // ============================================================

    function _setVaultState() internal {
        vm.prank(sys.owner);
        sys.core
            .harnessSetLpVault(
                1000e18, // nav
                500e18, // shares
                2e18, // price
                2.5e18, // pricePeak
                true // isSeeded
            );
    }

    function test_getVaultNav_returns_correct_NAV() public {
        _setVaultState();
        assertEq(sys.core.getVaultNav(), 1000e18);
    }

    function test_getVaultShares_returns_correct_total_shares() public {
        _setVaultState();
        assertEq(sys.core.getVaultShares(), 500e18);
    }

    function test_getVaultPrice_returns_correct_price() public {
        _setVaultState();
        assertEq(sys.core.getVaultPrice(), 2e18);
    }

    function test_getVaultPricePeak_returns_correct_peak() public {
        _setVaultState();
        assertEq(sys.core.getVaultPricePeak(), 2.5e18);
    }

    function test_isVaultSeeded_returns_correct_status() public {
        _setVaultState();
        assertTrue(sys.core.isVaultSeeded());
    }

    function test_getVaultDrawdown_calculates_correctly() public {
        _setVaultState();
        // DD = 1 - price/peak = 1 - 2/2.5 = 0.2 (20%)
        assertEq(sys.core.getVaultDrawdown(), 0.2e18);
    }

    function test_getVaultDrawdown_returns_zero_when_price_gte_pricePeak() public {
        vm.prank(sys.owner);
        sys.core
            .harnessSetLpVault(
                1000e18,
                500e18,
                3e18, // price > pricePeak
                2.5e18,
                true
            );
        assertEq(sys.core.getVaultDrawdown(), 0);
    }

    function test_isVaultSeeded_returns_false_when_not_seeded() public {
        vm.prank(sys.owner);
        sys.core.harnessSetLpVault(0, 0, 0, 0, false);
        assertFalse(sys.core.isVaultSeeded());
    }

    // ============================================================
    // Risk config getter
    // ============================================================

    function test_getRiskConfig_returns_all_parameters() public {
        vm.prank(sys.owner);
        sys.core.setRiskConfig(0.3e18, 1.5e18, true);

        (uint256 lambda, uint256 kDrawdown, bool enforceAlpha) = sys.core.getRiskConfig();
        assertEq(lambda, 0.3e18);
        assertEq(kDrawdown, 1.5e18);
        assertTrue(enforceAlpha);
    }

    // ============================================================
    // Fee waterfall config getter
    // ============================================================

    function test_getFeeWaterfallConfig_returns_all_parameters() public {
        vm.startPrank(sys.owner);
        sys.core.setRiskConfig(0.3e18, 1e18, true);
        sys.core.setFeeWaterfallConfig(0.1e18, 0.7e18, 0.2e18, 0.1e18);
        vm.stopPrank();

        (uint256 rhoBS, int256 pdd, uint256 phiLP, uint256 phiBS, uint256 phiTR) = sys.core.getFeeWaterfallConfig();

        assertEq(rhoBS, 0.1e18);
        // pdd = -lambda = -0.3e18
        assertEq(pdd, -int256(0.3e18));
        assertEq(phiLP, 0.7e18);
        assertEq(phiBS, 0.2e18);
        assertEq(phiTR, 0.1e18);
    }

    // ============================================================
    // Capital stack getter
    // ============================================================

    function test_getCapitalStack_returns_both_values() public {
        // Fund owner with USDC and approve
        sys.payment.mint(sys.owner, 10_000e6);
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);
        sys.core.fundBackstop(5000e6);
        sys.core.fundTreasury(2000e6);
        vm.stopPrank();

        (uint256 backstopNav, uint256 treasuryNav) = sys.core.getCapitalStack();
        assertEq(backstopNav, 5000e18);
        assertEq(treasuryNav, 2000e18);
    }

    // ============================================================
    // Withdrawal lag getter
    // ============================================================

    function test_getWithdrawalLagBatches_returns_correct_value() public {
        vm.prank(sys.owner);
        sys.core.setWithdrawalLagBatches(5);
        assertEq(sys.core.getWithdrawalLagBatches(), 5);
    }

    // ============================================================
    // Config change events
    // ============================================================

    function test_emits_RiskConfigUpdated_on_setRiskConfig() public {
        vm.prank(sys.owner);
        vm.expectEmit(true, true, true, true);
        emit SignalsCore.RiskConfigUpdated(0.3e18, 1e18, true);
        sys.core.setRiskConfig(0.3e18, 1e18, true);
    }

    function test_emits_BackstopFunded_on_fundBackstop() public {
        sys.payment.mint(sys.owner, 1000e6);
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit SignalsCoreStorage.BackstopFunded(sys.owner, 1000e6, 1000e18);
        sys.core.fundBackstop(1000e6);
        vm.stopPrank();
    }

    function test_emits_TreasuryFunded_on_fundTreasury() public {
        sys.payment.mint(sys.owner, 500e6);
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit SignalsCoreStorage.TreasuryFunded(sys.owner, 500e6, 500e18);
        sys.core.fundTreasury(500e6);
        vm.stopPrank();
    }

    function test_emits_WithdrawalLagUpdated_on_setWithdrawalLagBatches() public {
        vm.prank(sys.owner);
        vm.expectEmit(true, true, true, true);
        emit SignalsCore.WithdrawalLagUpdated(3);
        sys.core.setWithdrawalLagBatches(3);
    }

    function test_emits_ModulesUpdated_on_setModules() public {
        vm.prank(sys.owner);
        vm.expectEmit(true, true, true, true);
        emit SignalsCore.ModulesUpdated(
            address(sys.tradeModule),
            address(sys.lifecycleModule),
            address(sys.riskModule),
            address(sys.vaultModule),
            address(sys.oracleModule)
        );
        sys.core
            .setModules(
                address(sys.tradeModule),
                address(sys.lifecycleModule),
                address(sys.riskModule),
                address(sys.vaultModule),
                address(sys.oracleModule)
            );
    }
}
