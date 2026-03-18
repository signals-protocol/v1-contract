// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/SignalsBaseTest.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

import "../../../../contracts/testonly/SignalsUSDToken.sol";
import "../../../../contracts/testonly/TestERC1967Proxy.sol";
import "../../../../contracts/position/SignalsPosition.sol";
import "../../../../contracts/modules/TradeModule.sol";
import "../../../../contracts/modules/MarketLifecycleModule.sol";
import "../../../../contracts/modules/LPVaultModule.sol";
import "../../../../contracts/modules/OracleModule.sol";
import "../../../../contracts/modules/RiskModule.sol";

/// @title Access / Upgrade Guards Foundry Tests
/// @notice Converted from test/module/core/upgrade.spec.ts (8 tests)
contract UpgradeTest is SignalsBaseTest {
    // ============================================================
    // Test: prevents re-initialization of SignalsPosition proxy
    // ============================================================

    function test_preventsReInitializationOfPositionProxy() public {
        address owner = makeAddr("owner");

        SignalsUSDToken coreStub = new SignalsUSDToken();
        SignalsPosition positionImpl = new SignalsPosition();
        bytes memory initData = abi.encodeCall(SignalsPosition.initialize, (address(coreStub), owner));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(positionImpl), initData);

        SignalsPosition positionProxy = SignalsPosition(address(proxy));

        vm.expectRevert(); // InvalidInitialization
        positionProxy.initialize(owner, owner);
    }

    // ============================================================
    // Tests: blocks direct module calls (onlyDelegated)
    // ============================================================

    function test_tradeModuleOpenPositionRevertsNotDelegated() public {
        TradeModule tradeModule = new TradeModule();

        vm.expectRevert(SE.NotDelegated.selector);
        tradeModule.openPosition(1, 0, 1, 1_000, 1);
    }

    function test_lpVaultModuleSeedVaultRevertsNotDelegated() public {
        LPVaultModule lpVaultModule = new LPVaultModule();

        vm.expectRevert(SE.NotDelegated.selector);
        lpVaultModule.seedVault(1_000_000);
    }

    function test_lifecycleModuleCreateMarketRevertsNotDelegated() public {
        MarketLifecycleModule lifecycleModule = new MarketLifecycleModule();

        vm.expectRevert(SE.NotDelegated.selector);
        lifecycleModule.createMarket(
            0, // minTick
            100, // maxTick
            10, // tickSpacing
            uint64(block.timestamp + 100), // startTimestamp
            uint64(block.timestamp + 200), // endTimestamp
            uint64(block.timestamp + 300), // settlementTimestamp
            10, // numBins
            WAD, // liquidityParameter
            address(0), // feePolicy
            address(0) // seedData
        );
    }

    function test_oracleModuleSetRedstoneConfigRevertsNotDelegated() public {
        OracleModule oracleModule = new OracleModule();

        vm.expectRevert(SE.NotDelegated.selector);
        oracleModule.setRedstoneConfig(
            bytes32("TEST"),
            8, // feedDecimals
            3600, // maxSampleDistance
            300 // futureTolerance
        );
    }

    function test_riskModuleGetAlphaLimitRevertsNotDelegated() public {
        RiskModule riskModule = new RiskModule();

        vm.expectRevert(SE.NotDelegated.selector);
        riskModule.getAlphaLimit(32, 0.2e18, 0.5e18);
    }

    // ============================================================
    // Test: rejects upgrade from non-owner
    // ============================================================

    function test_rejectsUpgradeFromNonOwner() public {
        address owner = makeAddr("owner");
        address attacker = makeAddr("attacker");

        SignalsUSDToken coreStub = new SignalsUSDToken();
        SignalsPosition positionImpl = new SignalsPosition();
        bytes memory initData = abi.encodeCall(SignalsPosition.initialize, (address(coreStub), owner));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(positionImpl), initData);

        SignalsPosition newImpl = new SignalsPosition();

        // Attempt upgrade from non-owner should revert
        vm.prank(attacker);
        vm.expectRevert();
        SignalsPosition(address(proxy)).upgradeToAndCall(address(newImpl), "");
    }
}
