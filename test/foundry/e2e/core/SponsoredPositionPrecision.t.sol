// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SettlementHelper.sol";
import "../../base/SeedHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title Sponsored Position Precision & Regression Tests
/// @notice 14 tests: token conservation, existing position regression, partial close rounding, exact math, gas.
contract SponsoredPositionPrecisionTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal sponsor;
    address internal beneficiary;
    address internal regularTrader;

    uint32 internal constant NUM_BINS = 4;
    uint128 internal constant QUANTITY = 5_000;
    uint256 internal constant FUND = 50_000_000;
    uint256 internal constant SEED = 20_000_000;

    uint256 internal marketId;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(5, 5);
        sponsor = sys.users[0];
        beneficiary = sys.users[1];
        regularTrader = sys.users[2];

        // Seed vault
        sys.payment.mint(sys.owner, SEED);
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), SEED);
        sys.core.seedVault(SEED);
        vm.stopPrank();

        // Fund sponsor and regularTrader
        for (uint256 i = 0; i < 2; i++) {
            address user = i == 0 ? sponsor : regularTrader;
            sys.payment.mint(user, FUND);
            vm.prank(user);
            sys.payment.approve(address(sys.core), type(uint256).max);
        }

        marketId = _createMarket();
    }

    function _createMarket() internal returns (uint256) {
        uint64 start = uint64(block.timestamp - 5);
        uint64 end = uint64(block.timestamp + 50);
        uint64 settlement = uint64(block.timestamp + 60);

        vm.prank(sys.owner);
        return sys.core
            .createMarketUniform(
                0, int256(uint256(NUM_BINS)), 1, start, end, settlement, NUM_BINS, WAD, address(sys.feePolicy)
            );
    }

    function _settleAt(uint256 tick) internal {
        SettlementHelper.settleMarket(vm, address(sys.core), sys.owner, marketId, tick);
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);
        (,,, uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);
    }

    // =========================================================
    // 1. Token conservation invariant (3 tests)
    // =========================================================

    function test_closePosition_token_conservation() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        address coreAddr = address(sys.core);
        uint256 coreBefore = sys.payment.balanceOf(coreAddr);
        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = sys.payment.balanceOf(beneficiary);

        vm.prank(beneficiary);
        sys.core.closePosition(positionId, 0);

        uint256 coreOutflow = coreBefore - sys.payment.balanceOf(coreAddr);
        uint256 sponsorInflow = sys.payment.balanceOf(sponsor) - sponsorBefore;
        uint256 beneficiaryInflow = sys.payment.balanceOf(beneficiary) - beneficiaryBefore;

        assertEq(coreOutflow, sponsorInflow + beneficiaryInflow);
        assertGe(sponsorInflow, 0);
        assertGe(beneficiaryInflow, 0);
    }

    function test_claimPayout_WIN_token_conservation() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        _settleAt(2); // tick 2 in [1,3) → win

        address coreAddr = address(sys.core);
        uint256 coreBefore = sys.payment.balanceOf(coreAddr);
        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = sys.payment.balanceOf(beneficiary);

        vm.prank(beneficiary);
        sys.core.claimPayout(positionId);

        uint256 coreOutflow = coreBefore - sys.payment.balanceOf(coreAddr);
        uint256 sponsorInflow = sys.payment.balanceOf(sponsor) - sponsorBefore;
        uint256 beneficiaryInflow = sys.payment.balanceOf(beneficiary) - beneficiaryBefore;

        assertEq(coreOutflow, QUANTITY);
        assertEq(sponsorInflow + beneficiaryInflow, QUANTITY);
    }

    function test_claimPayout_LOSS_zero_outflow() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        _settleAt(0); // tick 0 outside [1,3) → loss

        uint256 coreBefore = sys.payment.balanceOf(address(sys.core));

        vm.prank(beneficiary);
        sys.core.claimPayout(positionId);

        assertEq(sys.payment.balanceOf(address(sys.core)), coreBefore);
    }

    // =========================================================
    // 2. Existing position regression (4 tests)
    // =========================================================

    function test_regular_open_close_matches_calculateCloseProceeds() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();
        vm.prank(regularTrader);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000);

        uint256 expectedProceeds = sys.core.calculateCloseProceeds(positionId);

        uint256 before = sys.payment.balanceOf(regularTrader);
        vm.prank(regularTrader);
        sys.core.closePosition(positionId, 0);
        uint256 afterBal = sys.payment.balanceOf(regularTrader);

        assertEq(afterBal - before, expectedProceeds);
    }

    function test_regular_open_increase_close_roundtrip() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();
        vm.prank(regularTrader);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000);

        vm.prank(regularTrader);
        sys.core.increasePosition(positionId, 1_000, 10_000_000);

        uint256 before = sys.payment.balanceOf(regularTrader);
        vm.prank(regularTrader);
        sys.core.closePosition(positionId, 0);

        assertGt(sys.payment.balanceOf(regularTrader), before);
        assertFalse(sys.position.exists(positionId));
    }

    function test_regular_open_settle_claim_payout_equals_QUANTITY() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();
        vm.prank(regularTrader);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000);

        _settleAt(2); // WIN

        uint256 before = sys.payment.balanceOf(regularTrader);
        vm.prank(regularTrader);
        sys.core.claimPayout(positionId);

        assertEq(sys.payment.balanceOf(regularTrader) - before, QUANTITY);
    }

    function test_sponsor_balance_unchanged_during_regular_lifecycle() public {
        uint256 sponsorBal = sys.payment.balanceOf(sponsor);

        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();
        vm.prank(regularTrader);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000);
        assertEq(sys.payment.balanceOf(sponsor), sponsorBal);

        vm.prank(regularTrader);
        sys.core.closePosition(positionId, 0);
        assertEq(sys.payment.balanceOf(sponsor), sponsorBal);
    }

    // =========================================================
    // 3. Partial close rounding (2 tests)
    // =========================================================

    function test_three_way_partial_close_principal_sum_equals_original() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);
        uint256 originalCost = sys.core.getSponsoredCost(positionId);

        // Close in 3 uneven parts: 33%, 33%, 34%
        uint128 part1 = uint128((uint256(QUANTITY) * 33) / 100);
        uint128 part2 = uint128((uint256(QUANTITY) * 33) / 100);

        vm.prank(beneficiary);
        sys.core.decreasePosition(positionId, part1, 0);
        uint256 costAfter1 = sys.core.getSponsoredCost(positionId);

        vm.prank(beneficiary);
        sys.core.decreasePosition(positionId, part2, 0);
        uint256 costAfter2 = sys.core.getSponsoredCost(positionId);

        vm.prank(beneficiary);
        sys.core.closePosition(positionId, 0);

        uint256 principal1 = originalCost - costAfter1;
        uint256 principal2 = costAfter1 - costAfter2;
        uint256 principal3 = costAfter2;
        uint256 totalPrincipal = principal1 + principal2 + principal3;

        assertEq(totalPrincipal, originalCost);
    }

    function test_single_unit_partial_closes_no_stuck_dust() public {
        uint128 smallQty = 10;
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, smallQty);
        uint256 positionId = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, smallQty, cost + 1_000_000);

        for (uint128 i = 0; i < smallQty - 1; i++) {
            vm.prank(beneficiary);
            sys.core.decreasePosition(positionId, 1, 0);
        }
        vm.prank(beneficiary);
        sys.core.closePosition(positionId, 0);

        assertFalse(sys.position.exists(positionId));
        assertEq(sys.core.getSponsoredCost(positionId), 0);
    }

    // =========================================================
    // 4. Exact proceeds math (2 tests)
    // =========================================================

    function test_WIN_claim_sponsor_gets_sponsoredCost_user_gets_remainder() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);
        uint256 sponsoredCost = sys.core.getSponsoredCost(positionId);

        _settleAt(2); // WIN

        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = sys.payment.balanceOf(beneficiary);

        vm.prank(beneficiary);
        sys.core.claimPayout(positionId);

        assertEq(sys.payment.balanceOf(sponsor) - sponsorBefore, sponsoredCost);
        assertEq(sys.payment.balanceOf(beneficiary) - beneficiaryBefore, QUANTITY - sponsoredCost);
    }

    function test_WIN_batchClaim_sponsored_and_regular() public {
        // Sponsored position
        uint256 cost1 = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 sponsoredPosId = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost1 + 1_000_000);

        // Regular position for same beneficiary (fund them)
        sys.payment.mint(beneficiary, FUND);
        vm.prank(beneficiary);
        sys.payment.approve(address(sys.core), type(uint256).max);
        uint256 cost2 = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 regularPosId = sys.position.nextId();
        vm.prank(beneficiary);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost2 + 1_000_000);

        uint256 sponsoredCost = sys.core.getSponsoredCost(sponsoredPosId);

        _settleAt(2); // both WIN

        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = sys.payment.balanceOf(beneficiary);

        // Batch claim
        uint256[] memory ids = new uint256[](2);
        ids[0] = sponsoredPosId;
        ids[1] = regularPosId;
        vm.prank(beneficiary);
        sys.core.batchClaimPayout(ids);

        assertEq(sys.payment.balanceOf(sponsor) - sponsorBefore, sponsoredCost);
        uint256 expectedBeneficiary = (QUANTITY - sponsoredCost) + QUANTITY;
        assertEq(sys.payment.balanceOf(beneficiary) - beneficiaryBefore, expectedBeneficiary);
    }

    // =========================================================
    // 5. Gas overhead (1 test)
    // =========================================================

    function test_openPositionFor_gas_overhead_under_60k() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 maxCost = cost + 1_000_000;

        // Regular open
        uint256 gasBefore1 = gasleft();
        vm.prank(regularTrader);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, maxCost);
        uint256 gasRegular = gasBefore1 - gasleft();

        // Need a new market for fair comparison
        marketId = _createMarket();

        uint256 cost2 = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 gasBefore2 = gasleft();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost2 + 1_000_000);
        uint256 gasSponsored = gasBefore2 - gasleft();

        uint256 overhead = gasSponsored > gasRegular ? gasSponsored - gasRegular : 0;
        assertLt(overhead, 60_000);
    }
}
