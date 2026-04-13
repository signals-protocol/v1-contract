// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/ForkBaseTest.sol";
import "../../../contracts/core/SignalsCore.sol";
import "../../../contracts/modules/TradeModule.sol";
import "../../../contracts/router/SignalsRouter.sol";
import "../../../contracts/interfaces/IAlgebraSwapRouter.sol";
import "../../../contracts/interfaces/ISignalsCore.sol";
import "../../../contracts/interfaces/ISignalsPosition.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title OperatorUpgradeForkTest
/// @notice End-to-end fork test for SIG-625: upgrade TradeModule on prod fork,
///         deploy new Router, and verify the approved-operator lifecycle pattern
///         works against real on-chain state with real Satsuma swaps.
///
///         Run with:
///         PROD_RPC_URL=... FOUNDRY_PROFILE=fork FORK_ENV=prod forge test --match-contract OperatorUpgradeForkTest -vv
contract OperatorUpgradeForkTest is ForkBaseTest {
    IAlgebraSwapRouter internal liveSwapRouter;
    IERC20 internal usdcE;
    IERC20 internal ctUSDToken;
    SignalsRouter internal router;

    // Event signatures for log scanning
    bytes32 constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    bytes32 constant POS_INCREASED_SIG = keccak256("PositionIncreased(uint256,address,uint128,uint128,uint256)");
    bytes32 constant POS_DECREASED_SIG = keccak256("PositionDecreased(uint256,address,uint128,uint128,uint256)");
    bytes32 constant POS_CLOSED_SIG = keccak256("PositionClosed(uint256,address,uint256)");
    bytes32 constant POS_CLAIMED_SIG = keccak256("PositionClaimed(uint256,address,uint256)");
    bytes32 constant FEE_CHARGED_SIG = keccak256(
        "TradeFeeCharged(address,uint256,uint256,bool,uint256,uint256,address)"
    );

    function setUp() public override {
        super.setUp();

        address swapRouterAddr = _tryContractAddr("SatsumaSwapRouter");
        address usdcEAddr = _tryContractAddr("USDCe");
        if (swapRouterAddr == address(0) || usdcEAddr == address(0)) return;

        liveSwapRouter = IAlgebraSwapRouter(swapRouterAddr);
        usdcE = IERC20(usdcEAddr);
        ctUSDToken = IERC20(paymentToken);

        // 1. Upgrade TradeModule on the live fork
        TradeModule newTrade = new TradeModule();
        SignalsCore newImpl = new SignalsCore();
        bytes memory setModulesData = abi.encodeCall(
            SignalsCore.setModules,
            (address(newTrade), core.lifecycleModule(), core.riskModule(), core.vaultModule(), core.oracleModule())
        );
        vm.prank(ownerSafe);
        core.upgradeToAndCall(address(newImpl), setModulesData);

        // 2. Deploy new Router
        router = new SignalsRouter(
            address(core),
            address(position),
            paymentToken,
            swapRouterAddr,
            address(0),
            address(this)
        );
        router.setAllowedToken(address(usdcE), true);
    }

    // ============================================================
    // Upgrade integrity
    // ============================================================

    function test_upgrade_preserves_vault_state() public {
        if (address(router) == address(0)) return;
        // If setUp completed, the upgrade already happened.
        // Verify vault reads still work.
        assertGt(core.getVaultNav(), 0, "vault nav zero after upgrade");
        assertGt(core.getVaultShares(), 0, "vault shares zero after upgrade");
        assertGt(core.getVaultPrice(), 0, "vault price zero after upgrade");
    }

    // ============================================================
    // Lifecycle via approved operator — event & transfer verification
    // ============================================================

    function test_increasePosition_emits_user_not_router() public {
        if (address(router) == address(0)) return;
        (address trader, uint256 positionId) = _openRealPosition();
        uint128 qtyBefore = position.getPosition(positionId).quantity;

        deal(address(usdcE), trader, 3e6);

        vm.startPrank(trader);
        usdcE.approve(address(router), 3e6);
        position.setApprovalForAll(address(router), true);

        vm.recordLogs();
        router.increasePositionWithSwap(positionId, address(usdcE), 3e6, 1, 2000, 3e6);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Quantity actually increased
        assertGt(position.getPosition(positionId).quantity, qtyBefore, "qty not increased");
        // Owner unchanged
        assertEq(position.ownerOf(positionId), trader, "owner changed");

        // Events must reference trader, not router
        _assertTraderInTradeEvents(logs, trader);
        // No position NFT transfers to/from router
        _assertNoRouterNFTTransfers(logs);
    }

    function test_decreasePosition_emits_user_not_router() public {
        if (address(router) == address(0)) return;
        (address trader, uint256 positionId) = _openRealPosition();
        uint128 qtyBefore = position.getPosition(positionId).quantity;

        vm.startPrank(trader);
        position.setApprovalForAll(address(router), true);

        vm.recordLogs();
        router.decreasePositionWithSwap(positionId, qtyBefore / 2, address(ctUSDToken), 0, 0);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertLt(position.getPosition(positionId).quantity, qtyBefore, "qty not decreased");
        assertTrue(position.exists(positionId), "position burned on partial decrease");
        assertEq(position.ownerOf(positionId), trader, "owner changed");

        _assertTraderInTradeEvents(logs, trader);
        _assertNoRouterNFTTransfers(logs);
    }

    function test_closePosition_emits_user_not_router() public {
        if (address(router) == address(0)) return;
        (address trader, uint256 positionId) = _openRealPosition();

        vm.startPrank(trader);
        position.setApprovalForAll(address(router), true);

        vm.recordLogs();
        router.closePositionWithSwap(positionId, address(ctUSDToken), 0, 0);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(position.exists(positionId), "position not burned");

        _assertTraderInTradeEvents(logs, trader);
        // Close still has a burn Transfer(owner, 0, id) — that's fine.
        // Only assert no router-address transfers.
        _assertNoRouterNFTTransfers(logs);
    }

    function test_claimPayout_emits_user_not_router() public {
        if (address(router) == address(0)) return;
        (address trader, uint256 positionId) = _openRealPosition();

        ISignalsPosition.Position memory pos = position.getPosition(positionId);
        ISignalsCore.Market memory m = core.getMarket(pos.marketId);

        // Settle the market: warp → markFailed → secondary settle → chunks
        uint64 submitWindow = core.settlementSubmitWindow();
        vm.warp(uint256(m.settlementTimestamp) + submitWindow + 1);

        vm.startPrank(ownerSafe);
        core.markSettlementFailed(pos.marketId);
        int256 winningTick = (pos.lowerTick + pos.upperTick) / 2;
        core.finalizeSecondarySettlement(pos.marketId, winningTick * 1e6);
        core.requestSettlementChunks(pos.marketId, m.numBins);
        vm.stopPrank();

        uint64 claimDelay = core.claimDelaySeconds();
        vm.warp(uint256(m.settlementTimestamp) + claimDelay + 1);

        // Clear existing ctUSD for clean measurement
        uint256 existingCtUSD = ctUSDToken.balanceOf(trader);
        if (existingCtUSD > 0) {
            vm.prank(trader);
            ctUSDToken.transfer(address(1), existingCtUSD);
        }

        vm.startPrank(trader);
        position.setApprovalForAll(address(router), true);

        vm.recordLogs();
        router.claimPayoutWithSwap(positionId, address(ctUSDToken), 0);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(position.exists(positionId), "position not burned");
        assertGt(ctUSDToken.balanceOf(trader), 0, "trader received no payout");

        _assertTraderInTradeEvents(logs, trader);
        _assertNoRouterNFTTransfers(logs);
    }

    // ============================================================
    // Non-owner caller rejected
    // ============================================================

    function test_nonOwner_cannot_use_router_lifecycle() public {
        if (address(router) == address(0)) return;
        (address trader, uint256 positionId) = _openRealPosition();

        // Trader approves router
        vm.prank(trader);
        position.setApprovalForAll(address(router), true);

        // Attacker tries to decrease trader's position → receives proceeds
        address attacker = makeAddr("attacker");
        uint128 halfQty = position.getPosition(positionId).quantity / 2;
        vm.prank(attacker);
        vm.expectRevert();
        router.decreasePositionWithSwap(positionId, halfQty, address(ctUSDToken), 0, 0);

        // Position unchanged
        assertEq(position.ownerOf(positionId), trader, "owner changed after attack");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _openRealPosition() internal returns (address trader, uint256 positionId) {
        (uint256 marketId, ISignalsCore.Market memory m) = _findActiveMarket();
        trader = makeAddr("forkTrader");
        deal(address(usdcE), trader, 10e6);

        vm.startPrank(trader);
        usdcE.approve(address(router), 10e6);
        int256 centerTick = ((m.minTick + m.maxTick) / 2 / m.tickSpacing) * m.tickSpacing;
        positionId = router.openPositionWithSwap(
            address(usdcE),
            5e6,
            1,
            marketId,
            centerTick,
            centerTick + m.tickSpacing,
            5000,
            5e6
        );
        vm.stopPrank();
    }

    function _findActiveMarket() internal view returns (uint256 marketId, ISignalsCore.Market memory m) {
        uint256 upper = core.nextMarketId() + 5;
        for (uint256 i = upper; i > 0; --i) {
            try core.getMarket(i) returns (ISignalsCore.Market memory candidate) {
                if (
                    candidate.isSeeded &&
                    !candidate.settled &&
                    block.timestamp >= candidate.startTimestamp &&
                    block.timestamp <= candidate.endTimestamp
                ) {
                    return (i, candidate);
                }
            } catch {
                continue;
            }
        }
        revert("no active market");
    }

    /// @dev Assert that PositionIncreased/Decreased/Closed/Claimed and TradeFeeCharged
    ///      all reference `expectedTrader`, NOT the router address.
    function _assertTraderInTradeEvents(Vm.Log[] memory logs, address expectedTrader) internal view {
        uint256 tradeEventCount;
        for (uint256 i; i < logs.length; i++) {
            bytes32 sig = logs[i].topics[0];
            if (
                sig == POS_INCREASED_SIG || sig == POS_DECREASED_SIG || sig == POS_CLOSED_SIG || sig == POS_CLAIMED_SIG
            ) {
                // topic[2] = indexed address trader
                address emittedTrader = address(uint160(uint256(logs[i].topics[2])));
                assertEq(emittedTrader, expectedTrader, "trade event has wrong trader");
                assertFalse(emittedTrader == address(router), "trade event has router as trader");
                tradeEventCount++;
            }
            if (sig == FEE_CHARGED_SIG) {
                // topic[1] = indexed address trader
                address emittedTrader = address(uint160(uint256(logs[i].topics[1])));
                assertEq(emittedTrader, expectedTrader, "fee event has wrong trader");
                tradeEventCount++;
            }
        }
        assertGt(tradeEventCount, 0, "no trade events found");
    }

    /// @dev Assert no ERC721 Transfer events where from or to is the router.
    ///      Burn transfers (to = address(0)) and mint transfers (from = address(0)) are fine.
    function _assertNoRouterNFTTransfers(Vm.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == TRANSFER_SIG && logs[i].emitter == address(position)) {
                address from = address(uint160(uint256(logs[i].topics[1])));
                address to = address(uint160(uint256(logs[i].topics[2])));
                assertFalse(from == address(router), "NFT transferred FROM router");
                assertFalse(to == address(router), "NFT transferred TO router");
            }
        }
    }
}
