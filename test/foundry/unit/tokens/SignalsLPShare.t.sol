// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../../../contracts/errors/SignalsErrors.sol";

/// @title SignalsLPShareTest
/// @notice Foundry unit tests for SignalsLPShare ERC-4626 async vault token.
/// @dev Mirrors test/unit/tokens/signalsLPShare.spec.ts (30 tests).
contract SignalsLPShareTest is FullSystemDeployer {
    FullSystem sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();

        // Seed vault with non-zero state for view function tests that need it.
        // Individual test sections re-set state as needed.
    }

    // ================================================================
    // Deployment
    // ================================================================

    function test_deployment_setsCorrectNameAndSymbol() public view {
        assertEq(sys.lpShare.name(), "Signals LP");
        assertEq(sys.lpShare.symbol(), "SIGLP");
    }

    function test_deployment_setsCorrectCoreAddress() public view {
        assertEq(sys.lpShare.core(), address(sys.core));
    }

    function test_deployment_setsCorrectAssetAddress() public view {
        assertEq(sys.lpShare.getAsset(), address(sys.payment));
    }

    function test_deployment_setsOwnerToOwnerSafe() public view {
        assertEq(sys.lpShare.owner(), sys.owner);
    }

    // ================================================================
    // OnlyCore modifier
    // ================================================================

    function test_onlyCore_revertsWhenNonCoreMints() public {
        vm.prank(sys.users[0]);
        vm.expectRevert(SignalsErrors.OnlyCore.selector);
        sys.lpShare.mint(sys.users[0], WAD);
    }

    function test_onlyCore_revertsWhenNonCoreBurns() public {
        vm.prank(sys.users[0]);
        vm.expectRevert(SignalsErrors.OnlyCore.selector);
        sys.lpShare.burn(sys.users[0], WAD);
    }

    // ================================================================
    // Async vault restrictions
    // ================================================================

    function test_asyncVault_revertsOnDirectDeposit() public {
        vm.expectRevert(SignalsErrors.AsyncVaultUseRequestDeposit.selector);
        sys.lpShare.deposit(WAD, sys.owner);
    }

    function test_asyncVault_revertsOnDirectMintShares() public {
        vm.expectRevert(SignalsErrors.AsyncVaultUseRequestDeposit.selector);
        sys.lpShare.mintShares(WAD, sys.owner);
    }

    function test_asyncVault_revertsOnDirectWithdraw() public {
        vm.expectRevert(SignalsErrors.AsyncVaultUseRequestWithdraw.selector);
        sys.lpShare.withdraw(WAD, sys.owner, sys.owner);
    }

    function test_asyncVault_revertsOnDirectRedeem() public {
        vm.expectRevert(SignalsErrors.AsyncVaultUseRequestWithdraw.selector);
        sys.lpShare.redeem(WAD, sys.owner, sys.owner);
    }

    // ================================================================
    // View functions (price = 2 WAD => 1 asset = 0.5 shares)
    // ================================================================

    function _seedVaultForViews() internal {
        vm.prank(sys.owner);
        sys.core.harnessSetLpVault(
            1000e18, // nav
            500e18, // shares
            2e18, // price
            2e18, // pricePeak
            true // isSeeded
        );
    }

    function test_view_convertToSharesReturnsCorrectValue() public {
        _seedVaultForViews();
        // 100 assets at price 2 = 50 shares
        uint256 shares = sys.lpShare.convertToShares(100e18);
        assertEq(shares, 50e18);
    }

    function test_view_convertToAssetsReturnsCorrectValue() public {
        _seedVaultForViews();
        // 50 shares at price 2 = 100 assets
        uint256 assets = sys.lpShare.convertToAssets(50e18);
        assertEq(assets, 100e18);
    }

    function test_view_previewDepositReturnsExpectedShares() public {
        _seedVaultForViews();
        uint256 shares = sys.lpShare.previewDeposit(100e18);
        assertEq(shares, 50e18);
    }

    function test_view_previewRedeemReturnsExpectedAssets() public {
        _seedVaultForViews();
        uint256 assets = sys.lpShare.previewRedeem(50e18);
        assertEq(assets, 100e18);
    }

    function test_view_totalAssetsReturnsVaultNAV() public {
        _seedVaultForViews();
        uint256 totalAssets = sys.lpShare.totalAssets();
        assertEq(totalAssets, 1000e18);
    }

    // ================================================================
    // ERC20 functionality
    // ================================================================

    function test_erc20_startsWithZeroTotalSupply() public view {
        assertEq(sys.lpShare.totalSupply(), 0);
    }

    function test_erc20_returns18Decimals() public view {
        assertEq(sys.lpShare.decimals(), 18);
    }

    // ================================================================
    // Edge cases — price = 0 fallback
    // ================================================================

    function _seedVaultPriceZero() internal {
        vm.prank(sys.owner);
        sys.core.harnessSetLpVault(0, 0, 0, 0, false);
    }

    function test_edge_convertToSharesReturns1to1WhenPriceZero() public {
        _seedVaultPriceZero();
        uint256 assets = 100e18;
        uint256 shares = sys.lpShare.convertToShares(assets);
        assertEq(shares, assets);
    }

    function test_edge_convertToAssetsReturns1to1WhenPriceZero() public {
        _seedVaultPriceZero();
        uint256 shares = 100e18;
        uint256 assets = sys.lpShare.convertToAssets(shares);
        assertEq(assets, shares);
    }

    function test_edge_previewDepositReturns1to1WhenPriceZero() public {
        _seedVaultPriceZero();
        uint256 assets = 100e18;
        uint256 shares = sys.lpShare.previewDeposit(assets);
        assertEq(shares, assets);
    }

    function test_edge_previewRedeemReturns1to1WhenPriceZero() public {
        _seedVaultPriceZero();
        uint256 shares = 100e18;
        uint256 assets = sys.lpShare.previewRedeem(shares);
        assertEq(assets, shares);
    }

    // ================================================================
    // Edge cases — zero input
    // ================================================================

    function test_edge_convertToSharesZeroReturnsZero() public {
        _seedVaultForViews();
        assertEq(sys.lpShare.convertToShares(0), 0);
    }

    function test_edge_convertToAssetsZeroReturnsZero() public {
        _seedVaultForViews();
        assertEq(sys.lpShare.convertToAssets(0), 0);
    }

    function test_edge_previewDepositZeroReturnsZero() public {
        _seedVaultForViews();
        assertEq(sys.lpShare.previewDeposit(0), 0);
    }

    function test_edge_previewRedeemZeroReturnsZero() public {
        _seedVaultForViews();
        assertEq(sys.lpShare.previewRedeem(0), 0);
    }

    // ================================================================
    // Edge cases — totalAssets fallback
    // ================================================================

    function test_edge_totalAssetsReturnsVaultNAVWhenAvailable() public {
        vm.prank(sys.owner);
        sys.core.harnessSetLpVault(1000e18, 500e18, 2e18, 2e18, true);
        assertEq(sys.lpShare.totalAssets(), 1000e18);
    }
}
