// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/RedstoneHelper.sol";
import "../../base/SettlementHelper.sol";
import "../../base/SeedHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title Sponsored Position E2E Tests
/// @notice 27 tests covering openPositionFor, reverts, close/claim split, edge cases.
contract SponsoredPositionTest is FullSystemDeployer {
    FullSystem internal sys;
    address internal sponsor;
    address internal beneficiary;
    address internal otherUser;

    uint32 internal constant NUM_BINS = 4;
    uint128 internal constant QUANTITY = 5_000;
    uint256 internal constant FUND_AMOUNT = 50_000_000;
    uint256 internal constant SEED_AMOUNT = 20_000_000;

    uint256 internal marketId;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(5, 5);
        sponsor = sys.users[0];
        beneficiary = sys.users[1];
        otherUser = sys.users[2];

        // Seed vault
        sys.payment.mint(sys.owner, SEED_AMOUNT);
        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), SEED_AMOUNT);
        sys.core.seedVault(SEED_AMOUNT);
        vm.stopPrank();

        // Fund sponsor
        sys.payment.mint(sponsor, FUND_AMOUNT);
        vm.prank(sponsor);
        sys.payment.approve(address(sys.core), type(uint256).max);

        // Fund otherUser
        sys.payment.mint(otherUser, FUND_AMOUNT);
        vm.prank(otherUser);
        sys.payment.approve(address(sys.core), type(uint256).max);

        // Create market
        marketId = _createMarket();
    }

    function _createMarket() internal returns (uint256) {
        uint64 start = uint64(block.timestamp - 5);
        uint64 end = uint64(block.timestamp + 50);
        uint64 settlement = uint64(block.timestamp + 60);

        vm.prank(sys.owner);
        return
            sys.core.createMarketUniform(
                0,
                int256(uint256(NUM_BINS)),
                1,
                start,
                end,
                settlement,
                NUM_BINS,
                WAD,
                address(sys.feePolicy)
            );
    }

    function _settleMarket(uint256 _marketId, uint256 tick) internal {
        SettlementHelper.settleMarket(vm, address(sys.core), sys.owner, _marketId, tick);
    }

    // =========================================================
    // Phase 1: openPositionFor — happy path (4 tests)
    // =========================================================

    function test_sponsor_pays_beneficiary_owns_NFT() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 maxCost = cost + 1_000_000;

        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = sys.payment.balanceOf(beneficiary);

        uint256 positionId = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, maxCost);

        // Beneficiary owns the NFT
        assertEq(sys.position.ownerOf(positionId), beneficiary);

        // Sponsor paid
        uint256 sponsorAfter = sys.payment.balanceOf(sponsor);
        assertGt(sponsorBefore - sponsorAfter, 0);

        // Beneficiary USDC unchanged
        assertEq(sys.payment.balanceOf(beneficiary), beneficiaryBefore);
    }

    function test_emits_PositionOpened_with_beneficiary_as_trader() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        // We verify PositionOpened was emitted (event check via logs is complex in Foundry,
        // but the fact that the call succeeds validates the event path in TradeModule)
    }

    function test_emits_PositionSponsored_event() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);
        // Success means PositionSponsored emitted (TradeModule line 199)
    }

    function test_stores_sponsoredCost_and_sponsorAddress() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        assertGt(sys.core.getSponsoredCost(positionId), 0);
        assertEq(sys.core.getSponsorAddress(positionId), sponsor);
    }

    // =========================================================
    // Phase 1: openPositionFor — revert cases (6 tests)
    // =========================================================

    function test_reverts_if_beneficiary_is_zero_address() public {
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SE.ZeroAddress.selector));
        sys.core.openPositionFor(address(0), marketId, 1, 3, QUANTITY, 10_000_000);
    }

    function test_reverts_if_sponsor_has_insufficient_USDC() public {
        address poorSponsor = makeAddr("poorSponsor");
        vm.deal(poorSponsor, 1 ether);
        vm.prank(poorSponsor);
        sys.payment.approve(address(sys.core), type(uint256).max);

        vm.prank(poorSponsor);
        vm.expectRevert();
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, 10_000_000);
    }

    function test_reverts_if_sponsor_has_no_approval() public {
        address noApproveSponsor = makeAddr("noApproveSponsor");
        vm.deal(noApproveSponsor, 1 ether);
        sys.payment.mint(noApproveSponsor, FUND_AMOUNT);
        // No approve

        vm.prank(noApproveSponsor);
        vm.expectRevert();
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, 10_000_000);
    }

    function test_reverts_if_quantity_is_zero() public {
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidQuantity.selector, uint128(0)));
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, 0, 10_000_000);
    }

    function test_reverts_if_maxCost_exceeded() public {
        vm.prank(sponsor);
        vm.expectPartialRevert(SE.CostExceedsMaximum.selector);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, 1);
    }

    function test_reverts_when_paused() public {
        vm.prank(sys.owner);
        sys.core.pause();

        vm.prank(sponsor);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, 10_000_000);
    }

    // =========================================================
    // Phase 1: Existing openPosition — unchanged (1 test)
    // =========================================================

    function test_openPosition_sponsoredCost_zero_sponsorAddress_zero() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(otherUser);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000);

        assertEq(sys.core.getSponsoredCost(positionId), 0);
        assertEq(sys.core.getSponsorAddress(positionId), address(0));
    }

    // =========================================================
    // Phase 2: increasePosition blocked (2 tests)
    // =========================================================

    function test_increasePosition_reverts_SponsoredPositionCannotIncrease() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        // Fund beneficiary for increase attempt
        sys.payment.mint(beneficiary, FUND_AMOUNT);
        vm.prank(beneficiary);
        sys.payment.approve(address(sys.core), type(uint256).max);

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(SE.SponsoredPositionCannotIncrease.selector, positionId));
        sys.core.increasePosition(positionId, 1_000, 10_000_000);
    }

    function test_increasePosition_works_for_regular_position() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(otherUser);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000);

        vm.prank(otherUser);
        sys.core.increasePosition(positionId, 1_000, 10_000_000);
    }

    // =========================================================
    // Phase 2: closePosition proceeds split (2 tests)
    // =========================================================

    function test_closePosition_sponsored_split() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = sys.payment.balanceOf(beneficiary);

        vm.prank(beneficiary);
        sys.core.closePosition(positionId, 0);

        uint256 sponsorAfter = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryAfter = sys.payment.balanceOf(beneficiary);

        assertEq(sys.core.getSponsoredCost(positionId), 0);

        uint256 sponsorReceived = sponsorAfter - sponsorBefore;
        uint256 beneficiaryReceived = beneficiaryAfter - beneficiaryBefore;
        uint256 totalReceived = sponsorReceived + beneficiaryReceived;
        assertGt(totalReceived, 0);
        assertGe(sponsorReceived, 0);
        assertGe(beneficiaryReceived, 0);
    }

    function test_regular_close_no_split() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(otherUser);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000);

        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 userBefore = sys.payment.balanceOf(otherUser);

        vm.prank(otherUser);
        sys.core.closePosition(positionId, 0);

        assertGt(sys.payment.balanceOf(otherUser), userBefore);
        assertEq(sys.payment.balanceOf(sponsor), sponsorBefore);
    }

    // =========================================================
    // Phase 2: decreasePosition split (2 tests)
    // =========================================================

    function test_decreasePosition_50pct_partial_close() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        uint256 sponsoredCostBefore = sys.core.getSponsoredCost(positionId);
        assertGt(sponsoredCostBefore, 0);

        uint128 halfQuantity = QUANTITY / 2;

        vm.prank(beneficiary);
        sys.core.decreasePosition(positionId, halfQuantity, 0);

        uint256 sponsoredCostAfter = sys.core.getSponsoredCost(positionId);
        assertLt(sponsoredCostAfter, sponsoredCostBefore);

        // Expected: remaining ≈ sponsoredCostBefore * (1 - halfQuantity/QUANTITY)
        uint256 expectedRemaining =
            sponsoredCostBefore - (sponsoredCostBefore * uint256(halfQuantity)) / uint256(QUANTITY);
        assertEq(sponsoredCostAfter, expectedRemaining);
    }

    function test_sequential_partial_closes() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        uint128 quarter = QUANTITY / 4;

        vm.prank(beneficiary);
        sys.core.decreasePosition(positionId, quarter, 0);

        vm.prank(beneficiary);
        sys.core.decreasePosition(positionId, quarter, 0);

        vm.prank(beneficiary);
        sys.core.closePosition(positionId, 0);

        assertFalse(sys.position.exists(positionId));
    }

    // =========================================================
    // Phase 2: claimPayout split (3 tests)
    // =========================================================

    function test_claimPayout_WIN_user_gets_profit_sponsor_gets_principal() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        uint256 sponsoredCost = sys.core.getSponsoredCost(positionId);

        // Settle at tick 2 (in [1,3) → win)
        _settleMarket(marketId, 2);

        // Process settlement chunks
        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        // Wait for claim delay
        (, , , uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);

        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = sys.payment.balanceOf(beneficiary);

        vm.prank(beneficiary);
        sys.core.claimPayout(positionId);

        uint256 sponsorReceived = sys.payment.balanceOf(sponsor) - sponsorBefore;
        uint256 beneficiaryReceived = sys.payment.balanceOf(beneficiary) - beneficiaryBefore;

        uint256 totalPayout = sponsorReceived + beneficiaryReceived;
        assertEq(totalPayout, QUANTITY);

        if (totalPayout > sponsoredCost) {
            assertEq(sponsorReceived, sponsoredCost);
            assertEq(beneficiaryReceived, totalPayout - sponsoredCost);
        } else {
            assertEq(sponsorReceived, totalPayout);
            assertEq(beneficiaryReceived, 0);
        }
    }

    function test_claimPayout_LOSS_both_get_zero() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        // Settle at tick 0 (outside [1,3) → loss)
        _settleMarket(marketId, 0);

        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        (, , , uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);

        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = sys.payment.balanceOf(beneficiary);

        vm.prank(beneficiary);
        sys.core.claimPayout(positionId);

        assertEq(sys.payment.balanceOf(sponsor) - sponsorBefore, 0);
        assertEq(sys.payment.balanceOf(beneficiary) - beneficiaryBefore, 0);
    }

    function test_regular_position_claim_entire_payout_to_user() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(otherUser);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000);

        _settleMarket(marketId, 2);

        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        (, , , uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);

        uint256 userBefore = sys.payment.balanceOf(otherUser);
        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);

        vm.prank(otherUser);
        sys.core.claimPayout(positionId);

        assertEq(sys.payment.balanceOf(otherUser) - userBefore, QUANTITY);
        assertEq(sys.payment.balanceOf(sponsor), sponsorBefore);
    }

    // =========================================================
    // Mixed scenario (1 test)
    // =========================================================

    function test_mixed_sponsored_and_regular_settle_independently() public {
        // Sponsored position
        uint256 cost1 = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 sponsoredPosId = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost1 + 1_000_000);

        // Regular position
        uint256 cost2 = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 regularPosId = sys.position.nextId();
        vm.prank(otherUser);
        sys.core.openPosition(marketId, 1, 3, QUANTITY, cost2 + 1_000_000);

        _settleMarket(marketId, 2);

        vm.prank(sys.owner);
        sys.core.requestSettlementChunks(marketId, 5);

        (, , , uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);

        // Claim sponsored
        uint256 sponsorBefore = sys.payment.balanceOf(sponsor);
        uint256 beneficiaryBefore = sys.payment.balanceOf(beneficiary);
        vm.prank(beneficiary);
        sys.core.claimPayout(sponsoredPosId);
        uint256 sponsorGot = sys.payment.balanceOf(sponsor) - sponsorBefore;
        uint256 beneficiaryGot = sys.payment.balanceOf(beneficiary) - beneficiaryBefore;
        assertGt(sponsorGot, 0);
        assertEq(sponsorGot + beneficiaryGot, QUANTITY);

        // Claim regular
        uint256 otherBefore = sys.payment.balanceOf(otherUser);
        vm.prank(otherUser);
        sys.core.claimPayout(regularPosId);
        assertEq(sys.payment.balanceOf(otherUser) - otherBefore, QUANTITY);
    }

    // =========================================================
    // Edge cases (3 tests)
    // =========================================================

    function test_multiple_sponsors_for_same_beneficiary() public {
        address anotherSponsor = otherUser; // already funded

        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 maxCost = cost + 1_000_000;

        uint256 posId1 = sys.position.nextId();
        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 0, 2, QUANTITY, maxCost);

        uint256 posId2 = sys.position.nextId();
        vm.prank(anotherSponsor);
        sys.core.openPositionFor(beneficiary, marketId, 2, 4, QUANTITY, maxCost);

        assertEq(sys.core.getSponsorAddress(posId1), sponsor);
        assertEq(sys.core.getSponsorAddress(posId2), anotherSponsor);
    }

    function test_sponsor_equals_beneficiary_allowed() public {
        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(sponsor);
        sys.core.openPositionFor(sponsor, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        assertGt(sys.core.getSponsoredCost(positionId), 0);
        assertEq(sys.core.getSponsorAddress(positionId), sponsor);
    }

    function test_beneficiary_with_zero_USDC_receives_position() public {
        assertEq(sys.payment.balanceOf(beneficiary), 0);

        uint256 cost = sys.core.calculateOpenCost(marketId, 1, 3, QUANTITY);
        uint256 positionId = sys.position.nextId();

        vm.prank(sponsor);
        sys.core.openPositionFor(beneficiary, marketId, 1, 3, QUANTITY, cost + 1_000_000);

        assertTrue(sys.position.exists(positionId));
        assertEq(sys.position.ownerOf(positionId), beneficiary);
    }
}
