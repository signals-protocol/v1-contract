// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/TradeModuleDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {SignalsPosition} from "../../../../contracts/position/SignalsPosition.sol";
import {TradeModule} from "../../../../contracts/modules/TradeModule.sol";

/// @title Events & Position Lifecycle Integration Tests
/// @notice Tests correct event emission and state changes for position lifecycle (21 tests from events.spec.ts)
contract EventsTest is TradeModuleDeployer {
    TradeModuleSystem internal sys;
    uint256 internal constant MARKET_ID = 1;

    function setUp() public override {
        super.setUp();
        sys = deployMinimalTradeSystem();
    }

    // ============================================================
    // SignalsPosition Events
    // ============================================================

    function test_emits_PositionMinted_on_openPosition() public {
        uint256 nextId = sys.position.nextId();
        address user = sys.users[0];

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(sys.position));
        emit SignalsPosition.PositionMinted(nextId, user, MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY));
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);
    }

    function test_emits_PositionUpdated_on_increasePosition() public {
        address user = sys.users[0];
        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);

        uint128 qtyBefore = sys.position.getPosition(positionId).quantity;

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(sys.position));
        emit SignalsPosition.PositionUpdated(positionId, qtyBefore, qtyBefore + uint128(SMALL_QUANTITY));
        sys.core.increasePosition(positionId, uint128(SMALL_QUANTITY), 50e6);
    }

    function test_emits_PositionUpdated_on_decreasePosition() public {
        address user = sys.users[0];
        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);

        uint128 qtyBefore = sys.position.getPosition(positionId).quantity;

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(sys.position));
        emit SignalsPosition.PositionUpdated(positionId, qtyBefore, qtyBefore - uint128(SMALL_QUANTITY));
        sys.core.decreasePosition(positionId, uint128(SMALL_QUANTITY), 0);
    }

    function test_emits_PositionBurned_on_closePosition() public {
        address user = sys.users[0];
        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);

        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(sys.position));
        emit SignalsPosition.PositionBurned(positionId, user);
        sys.core.closePosition(positionId, 0);
    }

    // ============================================================
    // TradeModule Events
    // ============================================================

    function test_emits_PositionClosed_on_closePosition() public {
        address user = sys.users[0];
        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);

        // PositionClosed is emitted from core address (delegatecall from TradeModule)
        vm.prank(user);
        vm.expectEmit(true, true, false, false, address(sys.core));
        emit TradeModule.PositionClosed(positionId, user, 0);
        sys.core.closePosition(positionId, 0);
    }

    // ============================================================
    // Position State Changes
    // ============================================================

    function test_openPosition_creates_new_position() public {
        address user = sys.users[0];
        assertEq(sys.position.balanceOf(user), 0);

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);

        assertEq(sys.position.balanceOf(user), 1);
    }

    function test_increasePosition_increases_quantity() public {
        address user = sys.users[0];
        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);

        uint128 qtyBefore = sys.position.getPosition(positionId).quantity;

        vm.prank(user);
        sys.core.increasePosition(positionId, uint128(SMALL_QUANTITY), 50e6);

        uint128 qtyAfter = sys.position.getPosition(positionId).quantity;
        assertGt(qtyAfter, qtyBefore);
    }

    function test_decreasePosition_decreases_quantity() public {
        address user = sys.users[0];
        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);

        uint128 qtyBefore = sys.position.getPosition(positionId).quantity;

        vm.prank(user);
        sys.core.decreasePosition(positionId, uint128(SMALL_QUANTITY), 0);

        uint128 qtyAfter = sys.position.getPosition(positionId).quantity;
        assertLt(qtyAfter, qtyBefore);
    }

    function test_closePosition_removes_position() public {
        address user = sys.users[0];
        uint256 positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);

        assertEq(sys.position.balanceOf(user), 1);

        vm.prank(user);
        sys.core.closePosition(positionId, 0);

        assertEq(sys.position.balanceOf(user), 0);
    }

    // ============================================================
    // Multiple Users
    // ============================================================

    function test_tracks_positions_per_user_correctly() public {
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 4,
            endOffset: 10_000,
            liquidityParameter: WAD
        });
        TradeModuleSystem memory multi = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 2,
                fundAmount: 100_000e6,
                submitWindow: 300,
                settlementWindow: 60
            })
        );

        address user1 = multi.users[0];
        address user2 = multi.users[1];

        uint256 pos1Id = multi.position.nextId();
        vm.prank(user1);
        multi.core.openPosition(1, int256(0), int256(2), uint128(SMALL_QUANTITY), 50e6);

        uint256 pos2Id = multi.position.nextId();
        vm.prank(user2);
        multi.core.openPosition(1, int256(2), int256(4), uint128(SMALL_QUANTITY), 50e6);

        assertEq(multi.position.balanceOf(user1), 1);
        assertEq(multi.position.balanceOf(user2), 1);
        assertEq(multi.position.ownerOf(pos1Id), user1);
        assertEq(multi.position.ownerOf(pos2Id), user2);
    }

    function test_users_can_trade_in_same_market_independently() public {
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 4,
            endOffset: 10_000,
            liquidityParameter: WAD
        });
        TradeModuleSystem memory multi = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 2,
                fundAmount: 100_000e6,
                submitWindow: 300,
                settlementWindow: 60
            })
        );

        address user1 = multi.users[0];
        address user2 = multi.users[1];

        uint256 pos1Id = multi.position.nextId();
        vm.prank(user1);
        multi.core.openPosition(1, int256(0), int256(2), uint128(SMALL_QUANTITY), 50e6);

        vm.prank(user2);
        multi.core.openPosition(1, int256(2), int256(4), uint128(SMALL_QUANTITY), 50e6);

        // User1 closes
        vm.prank(user1);
        multi.core.closePosition(pos1Id, 0);

        // User2 still has position
        assertEq(multi.position.balanceOf(user2), 1);
        // User1 has no positions
        assertEq(multi.position.balanceOf(user1), 0);
    }

    // ============================================================
    // Full Lifecycle
    // ============================================================

    function test_complete_position_lifecycle_works_correctly() public {
        address user = sys.users[0];
        uint256 positionId = sys.position.nextId();

        // Open
        vm.prank(user);
        vm.expectEmit(true, false, false, false, address(sys.position));
        emit SignalsPosition.PositionMinted(
            positionId,
            user,
            MARKET_ID,
            int256(0),
            int256(2),
            uint128(MEDIUM_QUANTITY)
        );
        sys.core.openPosition(MARKET_ID, int256(0), int256(2), uint128(MEDIUM_QUANTITY), 100e6);

        assertGt(positionId, 0);

        // Increase
        vm.prank(user);
        sys.core.increasePosition(positionId, uint128(SMALL_QUANTITY), 50e6);

        // Decrease
        vm.prank(user);
        sys.core.decreasePosition(positionId, uint128(SMALL_QUANTITY), 0);

        // Close
        vm.prank(user);
        vm.expectEmit(true, true, false, false, address(sys.position));
        emit SignalsPosition.PositionBurned(positionId, user);
        sys.core.closePosition(positionId, 0);

        // Position removed
        assertEq(sys.position.balanceOf(user), 0);
    }
}
