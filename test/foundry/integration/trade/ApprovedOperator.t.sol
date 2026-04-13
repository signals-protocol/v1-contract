// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/SettlementHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {TradeModule} from "../../../../contracts/modules/TradeModule.sol";
import {MockTraderFeePolicy} from "../../../../contracts/testonly/MockTraderFeePolicy.sol";
import {ISignalsCore} from "../../../../contracts/interfaces/ISignalsCore.sol";

contract ApprovedOperatorTest is FullSystemDeployer {
    FullSystem internal sys;

    address internal trader;
    address internal operator;
    address internal outsider;

    uint256 internal marketId;

    uint128 internal constant POSITION_QTY = 5_000;
    uint128 internal constant INCREASE_QTY = 2_500;
    uint256 internal constant FUND_AMOUNT = 50_000_000;
    uint256 internal constant SEED_AMOUNT = 20_000_000;

    function setUp() public override {
        super.setUp();

        sys = deployFullSystem(5, 5);
        trader = sys.users[0];
        operator = sys.users[1];
        outsider = sys.users[2];

        sys.payment.mint(sys.owner, SEED_AMOUNT);
        sys.payment.mint(trader, FUND_AMOUNT);
        sys.payment.mint(operator, FUND_AMOUNT);
        sys.payment.mint(outsider, FUND_AMOUNT);

        vm.startPrank(sys.owner);
        sys.payment.approve(address(sys.core), SEED_AMOUNT);
        sys.core.seedVault(SEED_AMOUNT);
        marketId = sys.core.createMarketUniform(
            0,
            4,
            1,
            uint64(block.timestamp - 5),
            uint64(block.timestamp + 50),
            uint64(block.timestamp + 60),
            4,
            WAD,
            address(sys.feePolicy)
        );
        vm.stopPrank();

        vm.prank(trader);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(operator);
        sys.payment.approve(address(sys.core), type(uint256).max);
        vm.prank(outsider);
        sys.payment.approve(address(sys.core), type(uint256).max);
    }

    function test_setApprovalForAll_operatorCanIncreasePosition_andFeePolicyUsesOwner() public {
        uint256 positionId = _openPosition(trader, 1, 3, POSITION_QTY);
        MockTraderFeePolicy feePolicy = _setTraderFeePolicy(trader, 0, 1);
        uint256 increaseCost = sys.core.calculateIncreaseCost(positionId, INCREASE_QTY);

        vm.prank(trader);
        sys.position.setApprovalForAll(operator, true);

        vm.expectEmit(true, true, false, true, address(sys.core));
        emit TradeModule.PositionIncreased(positionId, trader, INCREASE_QTY, POSITION_QTY + INCREASE_QTY, increaseCost);
        vm.expectEmit(true, true, true, true, address(sys.core));
        emit TradeModule.TradeFeeCharged(trader, marketId, positionId, true, increaseCost, 0, address(feePolicy));

        vm.prank(operator);
        sys.core.increasePosition(positionId, INCREASE_QTY, increaseCost);

        assertEq(sys.position.ownerOf(positionId), trader);
        assertEq(sys.position.getPosition(positionId).quantity, POSITION_QTY + INCREASE_QTY);
    }

    function test_getApproved_operatorCanDecreasePosition_andFeePolicyUsesOwner() public {
        uint256 positionId = _openPosition(trader, 1, 3, POSITION_QTY);
        MockTraderFeePolicy feePolicy = _setTraderFeePolicy(trader, 0, 1);
        uint128 sellQty = POSITION_QTY / 2;
        uint256 quotedProceeds = sys.core.calculateDecreaseProceeds(positionId, sellQty);

        vm.prank(trader);
        sys.position.approve(operator, positionId);

        vm.expectEmit(true, true, false, true, address(sys.core));
        emit TradeModule.PositionDecreased(positionId, trader, sellQty, POSITION_QTY - sellQty, quotedProceeds);
        vm.expectEmit(true, true, true, true, address(sys.core));
        emit TradeModule.TradeFeeCharged(trader, marketId, positionId, false, quotedProceeds, 0, address(feePolicy));

        uint256 operatorBefore = sys.payment.balanceOf(operator);

        vm.prank(operator);
        sys.core.decreasePosition(positionId, sellQty, quotedProceeds);

        assertEq(sys.position.ownerOf(positionId), trader);
        assertEq(sys.position.getPosition(positionId).quantity, POSITION_QTY - sellQty);
        assertEq(sys.payment.balanceOf(operator) - operatorBefore, quotedProceeds);
    }

    function test_unapprovedCallerCannotOperatePosition() public {
        uint256 positionId = _openPosition(trader, 1, 3, POSITION_QTY);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, outsider));
        sys.core.increasePosition(positionId, INCREASE_QTY, type(uint256).max);
    }

    function test_setApprovalForAll_operatorCanClaimPayout_andEventsUseOwner() public {
        uint256 positionId = _openPosition(trader, 1, 3, POSITION_QTY);

        vm.prank(trader);
        sys.position.setApprovalForAll(operator, true);

        _settleMarket(2);
        _warpToClaimOpen();

        uint256 operatorBefore = sys.payment.balanceOf(operator);

        vm.expectEmit(true, true, false, true, address(sys.core));
        emit TradeModule.PositionSettled(positionId, trader, POSITION_QTY, true);
        vm.expectEmit(true, true, false, true, address(sys.core));
        emit TradeModule.PositionClaimed(positionId, trader, POSITION_QTY);

        vm.prank(operator);
        sys.core.claimPayout(positionId);

        assertFalse(sys.position.exists(positionId));
        assertEq(sys.payment.balanceOf(operator) - operatorBefore, POSITION_QTY);
    }

    function test_setApprovalForAll_operatorCanBatchClaimPayout() public {
        uint256 positionId1 = _openPosition(trader, 1, 3, POSITION_QTY);
        uint256 positionId2 = _openPosition(trader, 1, 3, POSITION_QTY / 2);

        vm.prank(trader);
        sys.position.setApprovalForAll(operator, true);

        _settleMarket(2);
        _warpToClaimOpen();

        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId1;
        ids[1] = positionId2;

        uint256 operatorBefore = sys.payment.balanceOf(operator);

        vm.prank(operator);
        sys.core.batchClaimPayout(ids);

        assertFalse(sys.position.exists(positionId1));
        assertFalse(sys.position.exists(positionId2));
        assertEq(sys.payment.balanceOf(operator) - operatorBefore, POSITION_QTY + (POSITION_QTY / 2));
    }

    function _openPosition(
        address user,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) internal returns (uint256 positionId) {
        uint256 maxCost = sys.core.calculateOpenCost(marketId, lowerTick, upperTick, quantity) + 1_000_000;
        positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(marketId, lowerTick, upperTick, quantity, maxCost);
    }

    function _setTraderFeePolicy(
        address expectedTrader,
        uint256 expectedFee,
        uint256 fallbackFee
    ) internal returns (MockTraderFeePolicy feePolicy) {
        feePolicy = new MockTraderFeePolicy(expectedTrader, expectedFee, fallbackFee);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        market.feePolicy = address(feePolicy);

        vm.prank(sys.owner);
        sys.core.harnessSetMarket(marketId, market);
    }

    function _settleMarket(uint256 priceHuman) internal {
        SettlementHelper.settleMarket(vm, address(sys.core), sys.owner, marketId, priceHuman);
    }

    function _warpToClaimOpen() internal {
        (, , , uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);
    }
}
