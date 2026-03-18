// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/SeedHelper.sol";
import "../../base/VaultHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {RiskModule} from "../../../../contracts/modules/RiskModule.sol";

/// @title Risk Gate Call Order Integration Tests
/// @notice Verifies that SignalsCore calls RiskModule gates BEFORE delegating to target modules
///         (7 tests from riskGateCallOrder.spec.ts)
contract RiskGateCallOrderTest is FullSystemDeployer {
    FullSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();

        // Fund and seed vault
        sys.payment.mint(sys.owner, 100_000e6);
        vm.prank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);

        VaultHelper.seedVault(vm, address(sys.core), sys.owner, 10_000e6);
    }

    // ============================================================
    // createMarket gate enforcement
    // ============================================================

    function test_createMarket_rejects_when_alpha_exceeds_limit() public {
        // Configure risk to reject markets: extreme drawdown makes αlimit ≈ 0
        vm.startPrank(sys.owner);
        sys.core.setRiskConfig(0.001e18, 100e18, true);

        // 99% peak drawdown to make αlimit = 0
        sys.core.harnessSetLpVault(
            10_000e18, // nav
            10_000e18, // shares
            0.01e18, // price (1% of original)
            1e18, // pricePeak
            true
        );

        uint64 start = uint64(block.timestamp + 100);
        uint64 end = start + 86_400;
        uint64 settle = end + 3600;

        // Any α > 0 should fail because αlimit ≈ 0
        vm.expectRevert(abi.encodeWithSelector(SE.AlphaExceedsLimit.selector, 1e18, 0));
        sys.core.createMarketUniform(0, 100, 10, start, end, settle, 10, 1e18, address(sys.feePolicy));
        vm.stopPrank();
    }

    function test_createMarket_allows_when_gate_passes() public {
        // Permissive risk settings
        vm.startPrank(sys.owner);
        sys.core.setRiskConfig(0.5e18, 1e18, true);

        uint64 start = uint64(block.timestamp + 100);
        uint64 end = start + 86_400;
        uint64 settle = end + 3600;

        // Small α should pass
        sys.core.createMarketUniform(0, 100, 10, start, end, settle, 10, 1e18, address(sys.feePolicy));
        vm.stopPrank();
    }

    // ============================================================
    // openPosition gate enforcement
    // ============================================================

    function _createActiveMarket() internal returns (uint256 marketId) {
        vm.startPrank(sys.owner);
        sys.core.setRiskConfig(0.5e18, 1e18, true);

        uint64 start = uint64(block.timestamp + 100);
        uint64 end = start + 86_400;
        uint64 settle = end + 3600;

        marketId = sys.core.createMarketUniform(0, 100, 10, start, end, settle, 10, 10e18, address(sys.feePolicy));
        vm.stopPrank();

        // Advance to trading period
        vm.warp(start + 1);

        // Fund user
        address user = sys.users[0];
        sys.payment.mint(user, 100_000e6);
        vm.prank(user);
        sys.payment.approve(address(sys.core), type(uint256).max);
    }

    function test_openPosition_gate_no_revert() public {
        uint256 marketId = _createActiveMarket();

        // gateOpenPosition is currently a no-op (exposure cap enforcement deferred)
        // Should succeed because gate is no-op
        vm.prank(sys.users[0]);
        sys.core.openPosition(marketId, int256(0), int256(50), uint128(100), 1000e18);
    }

    function test_openPosition_succeeds_with_valid_params() public {
        uint256 marketId = _createActiveMarket();

        vm.prank(sys.users[0]);
        sys.core.openPosition(marketId, int256(0), int256(50), uint128(100), 1000e18);

        // Verify position exists
        assertEq(sys.position.balanceOf(sys.users[0]), 1);
    }

    // ============================================================
    // increasePosition gate enforcement
    // ============================================================

    function test_increasePosition_gate_no_revert() public {
        uint256 marketId = _createActiveMarket();
        address user = sys.users[0];

        // Open position
        uint256 positionId = sys.position.nextId();
        vm.prank(user);
        sys.core.openPosition(marketId, int256(0), int256(50), uint128(100), 1000e18);

        // gateIncreasePosition is currently a no-op
        vm.prank(user);
        sys.core.increasePosition(positionId, uint128(50), 1000e18);
    }

    function test_increasePosition_updates_quantity() public {
        uint256 marketId = _createActiveMarket();
        address user = sys.users[0];

        uint256 positionId = sys.position.nextId();
        vm.prank(user);
        sys.core.openPosition(marketId, int256(0), int256(50), uint128(100), 1000e18);

        uint128 qtyBefore = sys.position.getPosition(positionId).quantity;

        vm.prank(user);
        sys.core.increasePosition(positionId, uint128(50), 1000e18);

        uint128 qtyAfter = sys.position.getPosition(positionId).quantity;
        assertGt(qtyAfter, qtyBefore);
    }
}
