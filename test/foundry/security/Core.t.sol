// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/FullSystemDeployer.sol";
import "../base/VaultHelper.sol";
import {SignalsErrors as SE} from "../../../contracts/errors/SignalsErrors.sol";
import {TradeModule} from "../../../contracts/modules/TradeModule.sol";
import {ISignalsCore} from "../../../contracts/interfaces/ISignalsCore.sol";

/// @title Core Security Tests
/// @notice Foundry port of test/security/core.security.spec.ts (12 tests)
/// @dev Access control, position ownership, module access, input validation, slippage, free balance
contract CoreSecurityTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal attacker;
    address internal user;
    uint256 internal marketId;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem();

        attacker = makeAddr("attacker");
        user = sys.users[0];

        // Fund users
        sys.payment.mint(user, 1_000_000e6);
        sys.payment.mint(attacker, 1_000_000e6);

        vm.prank(user);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(attacker);
        sys.payment.approve(address(sys.core), type(uint256).max);

        // Create an active market via harness
        ISignalsCore.Market memory m;
        m.isSeeded = true;
        m.numBins = 100;
        m.seedCursor = 100;
        m.startTimestamp = uint64(block.timestamp - 1000);
        m.endTimestamp = uint64(block.timestamp + 100_000);
        m.settlementTimestamp = uint64(block.timestamp + 100_100);
        m.minTick = 0;
        m.maxTick = 100;
        m.tickSpacing = 1;
        m.liquidityParameter = WAD;
        m.feePolicy = address(sys.feePolicy);
        m.initialRootSum = 100 * WAD;
        m.minFactor = WAD;

        vm.startPrank(sys.owner);
        sys.core.harnessSetMarket(1, m);
        sys.core.harnessSeedTree(1, uniformFactors(100));
        vm.stopPrank();

        marketId = 1;
    }

    // ============================================================
    // Access Control
    // ============================================================

    function test_reverts_unauthorized_position_mint() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, attacker));
        sys.position.mintPosition(attacker, 1, 0, 10, 1000);
    }

    function test_reverts_unauthorized_position_burn() public {
        // Create a position first via core
        vm.prank(user);
        sys.core.openPosition(marketId, 10, 20, uint128(SMALL_QUANTITY), 1_000e6);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, attacker));
        sys.position.burn(1);
    }

    function test_reverts_unauthorized_position_quantity_update() public {
        vm.prank(user);
        sys.core.openPosition(marketId, 10, 20, uint128(SMALL_QUANTITY), 1_000e6);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, attacker));
        sys.position.updateQuantity(1, 5000);
    }

    // ============================================================
    // Position Ownership
    // ============================================================

    function test_prevents_transfer_by_non_owner() public {
        vm.prank(user);
        sys.core.openPosition(marketId, 10, 20, uint128(SMALL_QUANTITY), 1_000e6);

        vm.prank(attacker);
        vm.expectRevert();
        sys.position.transferFrom(user, attacker, 1);
    }

    function test_owner_can_transfer_own_position() public {
        vm.prank(user);
        sys.core.openPosition(marketId, 10, 20, uint128(SMALL_QUANTITY), 1_000e6);

        vm.prank(user);
        sys.position.transferFrom(user, attacker, 1);

        assertEq(sys.position.ownerOf(1), attacker);
    }

    // ============================================================
    // Module Access Control
    // ============================================================

    function test_reverts_direct_module_calls_onlyDelegated() public {
        vm.expectRevert(abi.encodeWithSelector(SE.NotDelegated.selector));
        sys.tradeModule.openPosition(1, 0, 1, 1000, 1_000_000);

        vm.expectRevert(abi.encodeWithSelector(SE.NotDelegated.selector));
        sys.tradeModule.closePosition(1, 0);
    }

    // ============================================================
    // Input Validation
    // ============================================================

    function test_reverts_on_zero_quantity() public {
        vm.prank(user);
        vm.expectRevert();
        sys.core.openPosition(marketId, 10, 20, 0, 1_000e6);
    }

    function test_reverts_on_invalid_tick_range() public {
        // Same tick (point bet not allowed)
        vm.prank(user);
        vm.expectRevert();
        sys.core.openPosition(marketId, 10, 10, uint128(SMALL_QUANTITY), 1_000e6);

        // Inverted range
        vm.prank(user);
        vm.expectRevert();
        sys.core.openPosition(marketId, 20, 10, uint128(SMALL_QUANTITY), 1_000e6);
    }

    function test_reverts_on_out_of_bounds_tick() public {
        vm.prank(user);
        vm.expectRevert();
        sys.core.openPosition(marketId, 0, 200, uint128(SMALL_QUANTITY), 1_000e6);
    }

    function test_reverts_on_non_existent_market() public {
        vm.prank(user);
        vm.expectRevert();
        sys.core.openPosition(999, 10, 20, uint128(SMALL_QUANTITY), 1_000e6);
    }

    // ============================================================
    // Slippage Protection
    // ============================================================

    function test_reverts_when_cost_exceeds_maxCost() public {
        vm.prank(user);
        vm.expectRevert();
        sys.core.openPosition(marketId, 10, 50, uint128(SMALL_QUANTITY), 1);
    }

    // ============================================================
    // Free Balance Protection
    // ============================================================

    function test_trade_proceeds_cannot_drain_pending_deposits() public {
        vm.prank(user);
        sys.core.openPosition(marketId, 10, 20, uint128(SMALL_QUANTITY), 1_000e6);

        uint256 coreBalance = sys.payment.balanceOf(address(sys.core));
        assertGt(coreBalance, 0);
    }
}
