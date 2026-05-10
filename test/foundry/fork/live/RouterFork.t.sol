// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/ForkLiveMarketTest.sol";
import "../../../../contracts/interfaces/IAlgebraSwapRouter.sol";
import "../../../../contracts/interfaces/ISignalsCore.sol";
import "../../../../contracts/interfaces/ISignalsPosition.sol";
import "../../../../contracts/router/SignalsRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RouterForkTest
/// @notice Fork tests against live Citrea mainnet — REAL Satsuma swap + REAL Core.
///         Requires an active market. Run with:
///         PROD_RPC_URL=... FOUNDRY_PROFILE=fork FORK_ENV=prod forge test --match-contract RouterForkTest --match-path 'test/foundry/fork/live/**' -vv
contract RouterForkTest is ForkLiveMarketTest {
    IAlgebraSwapRouter internal liveSwapRouter;
    IERC20 internal usdcE;
    IERC20 internal ctUSDToken;

    function setUp() public override {
        super.setUp();

        address swapRouterAddr = _tryContractAddr("SatsumaSwapRouter");
        address usdcEAddr = _tryContractAddr("USDCe");
        if (swapRouterAddr == address(0) || usdcEAddr == address(0)) return;

        liveSwapRouter = IAlgebraSwapRouter(swapRouterAddr);
        usdcE = IERC20(usdcEAddr);
        ctUSDToken = IERC20(paymentToken);
    }

    // ============================================================
    // ABI boundary
    // ============================================================

    function test_exactInputSingle_selector_matches_canonical_signature() public pure {
        bytes4 expected =
            bytes4(keccak256("exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))"));
        assertEq(IAlgebraSwapRouter.exactInputSingle.selector, expected, "selector mismatch");
    }

    function test_satsuma_swap_usdcE_to_ctUSD() public {
        if (address(liveSwapRouter) == address(0)) return;

        address trader = makeAddr("swapTrader");
        deal(address(usdcE), trader, 1e6);

        vm.startPrank(trader);
        usdcE.approve(address(liveSwapRouter), 1e6);
        uint256 amountOut = liveSwapRouter.exactInputSingle(
            IAlgebraSwapRouter.ExactInputSingleParams({
                tokenIn: address(usdcE),
                tokenOut: address(ctUSDToken),
                deployer: address(0),
                recipient: trader,
                deadline: block.timestamp + 600,
                amountIn: 1e6,
                amountOutMinimum: 1,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "swap returned zero");
    }

    // ============================================================
    // Full flow: REAL swap + REAL Core
    // ============================================================

    function test_fullFlow_openPositionWithSwap() public {
        (bool ok, SignalsRouter router, uint256 marketId, ISignalsCore.Market memory m) = _tryDeployRealRouter();
        if (!ok) return;

        address trader = makeAddr("openTrader");
        deal(address(usdcE), trader, 5e6);

        uint256 nextPosId = position.nextId();

        vm.startPrank(trader);
        usdcE.approve(address(router), 5e6);
        uint256 positionId = router.openPositionWithSwap(
            address(usdcE), 5e6, 1, marketId, m.minTick, m.minTick + m.tickSpacing, 5000, 5e6
        );
        vm.stopPrank();

        assertEq(positionId, nextPosId, "position ID");
        assertEq(position.ownerOf(positionId), trader, "trader owns NFT");
        assertEq(core.getSponsoredCost(positionId), 0, "not sponsored");
        assertEq(usdcE.balanceOf(address(router)), 0, "router 0 USDC.e");
    }

    function test_fullFlow_increasePositionWithSwap() public {
        (bool ok, SignalsRouter router, address trader, uint256 positionId) = _tryOpenRealPosition();
        if (!ok) return;

        uint256 qtyBefore = position.getPosition(positionId).quantity;
        deal(address(usdcE), trader, 3e6);

        vm.startPrank(trader);
        usdcE.approve(address(router), 3e6);
        position.setApprovalForAll(address(router), true);
        router.increasePositionWithSwap(positionId, address(usdcE), 3e6, 1, 2000, 3e6);
        vm.stopPrank();

        assertEq(position.ownerOf(positionId), trader, "trader owns NFT");
        assertGt(position.getPosition(positionId).quantity, qtyBefore, "quantity increased");
    }

    function test_fullFlow_decreasePositionWithSwap() public {
        (bool ok, SignalsRouter router, address trader, uint256 positionId) = _tryOpenRealPosition();
        if (!ok) return;

        uint256 qtyBefore = position.getPosition(positionId).quantity;
        vm.startPrank(trader);
        position.setApprovalForAll(address(router), true);
        router.decreasePositionWithSwap(positionId, uint128(qtyBefore / 2), address(ctUSDToken), 0, 0);
        vm.stopPrank();

        assertEq(position.ownerOf(positionId), trader, "trader still owns NFT");
        assertLt(position.getPosition(positionId).quantity, qtyBefore, "quantity decreased");
        assertTrue(position.exists(positionId), "position still exists (partial)");
    }

    function test_fullFlow_closePositionWithSwap() public {
        (bool ok, SignalsRouter router, address trader, uint256 positionId) = _tryOpenRealPosition();
        if (!ok) return;

        vm.startPrank(trader);
        position.setApprovalForAll(address(router), true);
        router.closePositionWithSwap(positionId, address(ctUSDToken), 0, 0);
        vm.stopPrank();

        assertFalse(position.exists(positionId), "position burned");
    }

    function test_fullFlow_claimPayoutWithSwap() public {
        (bool ok, SignalsRouter router, address trader, uint256 positionId) = _tryOpenRealPosition();
        if (!ok) return;

        // Get market and position info
        ISignalsPosition.Position memory pos = position.getPosition(positionId);
        ISignalsCore.Market memory m = core.getMarket(pos.marketId);

        // 1. Warp past end + settlement window + pending ops window
        uint64 submitWindow = core.settlementSubmitWindow();
        vm.warp(uint256(m.settlementTimestamp) + submitWindow + 1);

        // 2. Mark settlement as failed (owner only, during PendingOps)
        vm.startPrank(ownerSafe);
        core.markSettlementFailed(pos.marketId);

        // 3. Secondary settlement with tick value IN the position's range (so it's a winner)
        // Settlement value = tick * 10^(redstoneFeedDecimals - 2) since ticks are price/100
        int256 winningTick = (pos.lowerTick + pos.upperTick) / 2;
        int256 settlementValue = winningTick * 1e6; // 8 decimals, ticks are price*100 → value = tick * 1e6
        core.finalizeSecondarySettlement(pos.marketId, settlementValue);

        // 4. Request settlement chunks to set up payout reserve
        core.requestSettlementChunks(pos.marketId, m.numBins);
        vm.stopPrank();

        // 5. Warp past claim delay
        uint64 claimDelay = core.claimDelaySeconds();
        vm.warp(uint256(m.settlementTimestamp) + claimDelay + 1);

        // 6. Clear trader's existing ctUSD so we can measure payout cleanly
        uint256 existingCtUSD = ctUSDToken.balanceOf(trader);
        if (existingCtUSD > 0) {
            vm.prank(trader);
            ctUSDToken.transfer(address(1), existingCtUSD);
        }

        // 7. Claim via Router
        uint256 ctUSDBefore = ctUSDToken.balanceOf(trader);

        vm.startPrank(trader);
        position.setApprovalForAll(address(router), true);
        router.claimPayoutWithSwap(positionId, address(ctUSDToken), 0);
        vm.stopPrank();

        assertFalse(position.exists(positionId), "position burned after claim");
        assertGt(ctUSDToken.balanceOf(trader), ctUSDBefore, "trader received payout");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _tryDeployRealRouter()
        internal
        returns (bool ok, SignalsRouter router, uint256 marketId, ISignalsCore.Market memory m)
    {
        if (address(liveSwapRouter) == address(0)) return (false, router, 0, m);

        (bool found, uint256 activeMarketId, ISignalsCore.Market memory activeMarket) = _tryFindActiveMarket();
        if (!found) return (false, router, 0, m);

        router = new SignalsRouter(
            address(core), address(position), paymentToken, address(liveSwapRouter), address(0), address(this)
        );
        router.setAllowedToken(address(usdcE), true);
        return (true, router, activeMarketId, activeMarket);
    }

    function _tryOpenRealPosition()
        internal
        returns (bool ok, SignalsRouter router, address trader, uint256 positionId)
    {
        uint256 marketId;
        ISignalsCore.Market memory m;
        (ok, router, marketId, m) = _tryDeployRealRouter();
        if (!ok) return (false, router, trader, 0);

        trader = makeAddr("posTrader");
        deal(address(usdcE), trader, 10e6);

        vm.startPrank(trader);
        usdcE.approve(address(router), 10e6);
        // Use center ticks for meaningful cost/payout (edge ticks have near-zero cost)
        int256 centerTick = (m.minTick + m.maxTick) / 2;
        // Align to tick spacing
        centerTick = (centerTick / m.tickSpacing) * m.tickSpacing;
        positionId = router.openPositionWithSwap(
            address(usdcE), 5e6, 1, marketId, centerTick, centerTick + m.tickSpacing, 5000, 5e6
        );
        vm.stopPrank();
        return (true, router, trader, positionId);
    }
}
