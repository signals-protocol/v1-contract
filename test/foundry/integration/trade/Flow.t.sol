// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/TradeModuleDeployer.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title FlowTest
/// @notice Integration: open -> increase -> decrease -> close lifecycle, slippage, claim flows.
/// @dev Mirrors test/integration/trade/flow.spec.ts (13 tests).
contract FlowTest is TradeModuleDeployer {
    TradeModuleSystem sys;

    function setUp() public override {
        super.setUp();
        sys = deployMinimalTradeSystem();
    }

    // ============================================================
    // Core lifecycle
    // ============================================================

    function test_openIncrDecreaseClose_updatesBalancesAndCount() public {
        address user = sys.users[0];
        uint256 startBal = sys.payment.balanceOf(user);

        uint256 nextId = sys.position.nextId();
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 1_000, 5_000_000);

        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        assertEq(m.openPositionCount, 1);

        vm.prank(user);
        sys.core.increasePosition(nextId, 1_000, 5_000_000);
        vm.prank(user);
        sys.core.decreasePosition(nextId, 1_000, 0);
        vm.prank(user);
        sys.core.closePosition(nextId, 0);

        m = sys.core.harnessGetMarket(1);
        assertEq(m.openPositionCount, 0);
        assertFalse(sys.position.exists(nextId));

        uint256 endBal = sys.payment.balanceOf(user);
        assertLt(endBal, startBal, "should pay trading cost overall");
    }

    // ============================================================
    // Validation
    // ============================================================

    function test_rejectsZeroQuantity() public {
        vm.prank(sys.users[0]);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidQuantity.selector, uint128(0)));
        sys.core.openPosition(1, 0, 4, 0, 1_000_000);
    }

    function test_rejectsMisalignedTicks() public {
        // Deploy system with tickSpacing=2
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 2,
            minTick: 0,
            maxTick: 8,
            endOffset: 10_000,
            liquidityParameter: WAD
        });
        TradeModuleSystem memory sys2 = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 1,
                fundAmount: 100_000e6,
                submitWindow: 300,
                settlementWindow: 60
            })
        );
        vm.prank(sys2.users[0]);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidTickSpacing.selector, int256(1), int256(2)));
        sys2.core.openPosition(1, 1, 3, 1_000, 5_000_000);
    }

    function test_revertsOnUnseededMarket() public {
        // Deploy system with unseeded market
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 4,
            endOffset: 10_000,
            liquidityParameter: WAD
        });
        TradeModuleSystem memory sys2 = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 1,
                fundAmount: 100_000e6,
                submitWindow: 300,
                settlementWindow: 60
            })
        );

        // Overwrite market to be unseeded
        ISignalsCore.Market memory m = sys2.core.harnessGetMarket(1);
        m.isSeeded = false;
        m.seedCursor = 0;
        sys2.core.setMarket(1, m);

        vm.prank(sys2.users[0]);
        vm.expectRevert(SE.MarketNotSeeded.selector);
        sys2.core.openPosition(1, 0, 4, 1_000, 5_000_000);
    }

    function test_revertsOnInvalidTicks() public {
        vm.prank(sys.users[0]);
        vm.expectRevert(abi.encodeWithSelector(SE.RangeBinsOutOfBounds.selector, uint32(0), uint32(4), uint32(4)));
        sys.core.openPosition(1, 0, 5, 1_000, 5_000_000);
    }

    function test_calculateOpenCost_matchesActualDebit() public {
        address user = sys.users[0];
        uint256 quote = sys.core.calculateOpenCost(1, 0, 4, 1_000);
        uint256 balBefore = sys.payment.balanceOf(user);
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 1_000, quote);
        uint256 balAfter = sys.payment.balanceOf(user);
        assertEq(balBefore - balAfter, quote);
    }

    // ============================================================
    // Claim after settlement
    // ============================================================

    function test_claimAfterSettlement_burnsPosition() public {
        address user = sys.users[0];
        uint256 quote = sys.core.calculateOpenCost(1, 0, 4, 1_000);
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 1_000, quote);

        // Settle market — set timestamps to far past, outside position range so payout=0
        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        m.settled = true;
        m.endTimestamp = 1_600_000_000;
        m.settlementTimestamp = 1_600_000_000;
        m.settlementFinalizedAt = 1_600_000_000;
        m.settlementTick = 10; // outside [0,4)
        sys.core.setMarket(1, m);

        uint256 balBefore = sys.payment.balanceOf(user);
        vm.prank(user);
        sys.core.claimPayout(1);
        uint256 balAfter = sys.payment.balanceOf(user);

        assertEq(balAfter, balBefore, "losing position pays 0");
        assertFalse(sys.position.exists(1));
    }

    // ============================================================
    // Claim reverts
    // ============================================================

    function test_revertClaimNotSettled_thenTooEarly_thenDoubleClaim() public {
        address user = sys.users[0];
        uint256 quote = sys.core.calculateOpenCost(1, 0, 4, 1_000);
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 1_000, quote);

        // Not settled yet
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SE.MarketNotSettled.selector, uint256(1)));
        sys.core.claimPayout(1);

        // Settle but future timestamps (too early)
        ISignalsCore.Market memory m = sys.core.harnessGetMarket(1);
        m.settled = true;
        m.settlementTimestamp = uint64(block.timestamp + 3600);
        m.settlementFinalizedAt = uint64(block.timestamp + 3600);
        sys.core.setMarket(1, m);

        vm.prank(user);
        vm.expectPartialRevert(SE.ClaimTooEarly.selector);
        sys.core.claimPayout(1);

        // Make claimable - set to far past
        m.endTimestamp = 1_600_000_000;
        m.settlementTimestamp = 1_600_000_000;
        m.settlementFinalizedAt = 1_600_000_000;
        m.settlementTick = 10; // outside range
        sys.core.setMarket(1, m);

        vm.prank(user);
        sys.core.claimPayout(1);

        // Double claim → burned position reverts
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SE.PositionNotFound.selector, uint256(1)));
        sys.core.claimPayout(1);
    }

    // ============================================================
    // Slippage and fees
    // ============================================================

    function test_enforcesMaxCostAndMinProceeds_andAppliesFeePolicy() public {
        // Deploy with 1% fee
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 4,
            endOffset: 10_000,
            liquidityParameter: WAD
        });
        TradeModuleSystem memory sys2 = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 1,
                fundAmount: 100_000e6,
                submitWindow: 300,
                settlementWindow: 60
            })
        );

        // Re-deploy fee policy with 1%
        MockFeePolicy feePolicy1 = new MockFeePolicy(100);
        ISignalsCore.Market memory m = sys2.core.harnessGetMarket(1);
        m.feePolicy = address(feePolicy1);
        sys2.core.setMarket(1, m);

        address user = sys2.users[0];

        // maxCost too low
        vm.prank(user);
        vm.expectPartialRevert(SE.CostExceedsMaximum.selector);
        sys2.core.openPosition(1, 0, 4, 1_000, 1);

        // Open with generous maxCost
        uint256 quote = sys2.core.calculateOpenCost(1, 0, 4, 1_000);
        vm.prank(user);
        sys2.core.openPosition(1, 0, 4, 1_000, quote + 10_000);

        // minProceeds too high
        vm.prank(user);
        vm.expectPartialRevert(SE.ProceedsBelowMinimum.selector);
        sys2.core.decreasePosition(1, 500, quote);

        // Close with minProceeds=0
        vm.prank(user);
        sys2.core.closePosition(1, 0);
    }

    function test_revertsWhenAllowanceInsufficient() public {
        address user = sys.users[0];
        vm.prank(user);
        sys.payment.approve(address(sys.core), 0);
        vm.prank(user);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        sys.core.openPosition(1, 0, 4, 1_000, 5_000_000);
    }

    function test_calculateDecreaseProceeds_matchesActualCredit() public {
        address user = sys.users[0];
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 2_000, 10_000_000);
        uint256 posId = 1;

        uint256 decreaseProceeds = sys.core.calculateDecreaseProceeds(posId, 500);
        uint256 balBefore = sys.payment.balanceOf(user);
        vm.prank(user);
        sys.core.decreasePosition(posId, 500, 0);
        uint256 balAfter = sys.payment.balanceOf(user);

        assertEq(balAfter - balBefore, decreaseProceeds);
    }

    function test_revertsTradeAfterMarketEnd() public {
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 4,
            endOffset: 50,
            liquidityParameter: WAD
        });
        TradeModuleSystem memory sys2 = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 1,
                fundAmount: 100_000e6,
                submitWindow: 300,
                settlementWindow: 60
            })
        );
        ISignalsCore.Market memory m = sys2.core.harnessGetMarket(1);

        vm.warp(uint256(m.endTimestamp) + 1);
        vm.prank(sys2.users[0]);
        vm.expectRevert(SE.MarketExpired.selector);
        sys2.core.openPosition(1, 0, 4, 1_000, 5_000_000);
    }

    function test_revertsTradeBeforeMarketStart() public {
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 4,
            endOffset: 10_000,
            liquidityParameter: WAD
        });
        TradeModuleSystem memory sys2 = deployTradeModuleSystem(
            DeployOptions({
                markets: markets,
                userCount: 1,
                fundAmount: 100_000e6,
                submitWindow: 300,
                settlementWindow: 60
            })
        );
        // Overwrite start to future
        ISignalsCore.Market memory m = sys2.core.harnessGetMarket(1);
        m.startTimestamp = uint64(block.timestamp + 1000);
        m.endTimestamp = uint64(block.timestamp + 2000);
        sys2.core.setMarket(1, m);

        vm.prank(sys2.users[0]);
        vm.expectRevert(SE.MarketNotStarted.selector);
        sys2.core.openPosition(1, 0, 4, 1_000, 5_000_000);
    }

    function test_revertsDecreaseMoreThanOwnedQuantity() public {
        address user = sys.users[0];
        vm.prank(user);
        sys.core.openPosition(1, 0, 4, 1_000, 5_000_000);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SE.InsufficientPositionQuantity.selector, uint128(2_000), uint128(1_000))
        );
        sys.core.decreasePosition(1, 2_000, 0);
    }

    function test_revertsOperationsOnNonExistentPosition() public {
        address user = sys.users[0];

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SE.PositionNotFound.selector, uint256(999)));
        sys.core.increasePosition(999, 500, 5_000_000);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SE.PositionNotFound.selector, uint256(999)));
        sys.core.decreasePosition(999, 500, 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SE.PositionNotFound.selector, uint256(999)));
        sys.core.closePosition(999, 0);
    }
}
