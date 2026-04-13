// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/SettlementHelper.sol";
import {SignalsRouter} from "../../../../contracts/router/SignalsRouter.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";
import {TradeModule} from "../../../../contracts/modules/TradeModule.sol";
import {MockAlgebraSwapRouter} from "../../../../contracts/testonly/MockAlgebraSwapRouter.sol";
import {MockERC20} from "../../../../contracts/testonly/MockERC20.sol";

contract SignalsRouterTest is FullSystemDeployer {
    FullSystem internal sys;
    SignalsRouter internal router;
    MockAlgebraSwapRouter internal mockSwapRouter;
    MockERC20 internal inputToken;

    address internal owner;
    address internal user;

    uint256 internal marketId;

    uint128 internal constant POSITION_QTY = 5_000;
    uint128 internal constant INCREASE_QTY = 2_500;
    uint256 internal constant USER_FUND = 50_000_000;
    uint256 internal constant INPUT_FUND = 50_000_000;
    uint256 internal constant SEED_AMOUNT = 20_000_000;
    uint256 internal constant ROUTER_DUST = 777;
    uint256 internal constant RESCUE_DUST = 1_234_567;
    int256 internal constant LOWER_TICK = 1;
    int256 internal constant UPPER_TICK = 3;

    function setUp() public override {
        super.setUp();

        sys = deployFullSystem(5, 5);
        owner = sys.owner;
        user = sys.users[0];

        inputToken = new MockERC20("Bridged USDC", "USDC.e", 6);
        mockSwapRouter = new MockAlgebraSwapRouter();
        router = new SignalsRouter(
            address(sys.core),
            address(sys.position),
            address(sys.payment),
            address(mockSwapRouter),
            address(0),
            owner
        );

        sys.payment.mint(owner, SEED_AMOUNT);
        vm.startPrank(owner);
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

        sys.payment.mint(user, USER_FUND);
        inputToken.mint(user, INPUT_FUND);

        vm.prank(user);
        sys.payment.approve(address(sys.core), type(uint256).max);

        vm.prank(user);
        inputToken.approve(address(router), type(uint256).max);

        sys.payment.mint(address(mockSwapRouter), INPUT_FUND * 2);
        inputToken.mint(address(mockSwapRouter), INPUT_FUND * 2);

        mockSwapRouter.setRate(address(inputToken), address(sys.payment), 1e18);
        mockSwapRouter.setRate(address(sys.payment), address(inputToken), 1e18);
    }

    function test_openPositionWithSwap_opensPositionAndRefundsOnlyCurrentDelta() public {
        _allowToken(address(inputToken));

        uint256 positionId = sys.position.nextId();
        uint256 openCost = sys.core.calculateOpenCost(marketId, LOWER_TICK, UPPER_TICK, POSITION_QTY);
        uint256 inputAmount = openCost + 25_000;

        sys.payment.mint(address(router), ROUTER_DUST);
        uint256 userCtUSDBefore = sys.payment.balanceOf(user);

        vm.prank(user);
        router.openPositionWithSwap(
            address(inputToken),
            inputAmount,
            inputAmount,
            marketId,
            LOWER_TICK,
            UPPER_TICK,
            POSITION_QTY,
            inputAmount
        );

        assertEq(sys.position.ownerOf(positionId), user);
        assertEq(sys.core.getSponsoredCost(positionId), 0);
        assertEq(sys.core.getSponsorAddress(positionId), address(0));
        assertGt(sys.payment.balanceOf(user), userCtUSDBefore);
        assertEq(sys.payment.balanceOf(address(router)), ROUTER_DUST);
        assertEq(mockSwapRouter.swapCount(), 1);
    }

    function test_increasePositionWithSwap_returnsPositionToUser() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        vm.prank(user);
        router.increasePositionWithSwap(positionId, address(inputToken), 25_000, 25_000, INCREASE_QTY, 25_000);

        assertEq(sys.position.ownerOf(positionId), user);
        assertEq(sys.position.getPosition(positionId).quantity, POSITION_QTY + INCREASE_QTY);
        assertEq(sys.core.getSponsoredCost(positionId), 0);
        assertEq(mockSwapRouter.swapCount(), 1);
    }

    function test_decreasePositionWithSwap_partialDecreaseReturnsNftAndSwapsProceeds() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        router.decreasePositionWithSwap(positionId, POSITION_QTY / 2, address(inputToken), 1, 0);

        assertEq(sys.position.ownerOf(positionId), user);
        assertEq(sys.position.getPosition(positionId).quantity, POSITION_QTY / 2);
        assertGt(inputToken.balanceOf(user), userInputBefore);
        assertEq(mockSwapRouter.swapCount(), 1);
    }

    function test_closePositionWithSwap_ctUSDShortcutSkipsWhitelistAndSwap() public {
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        uint256 userCtUSDBefore = sys.payment.balanceOf(user);

        vm.prank(user);
        router.closePositionWithSwap(positionId, address(sys.payment), 0, 0);

        assertFalse(sys.position.exists(positionId));
        assertGt(sys.payment.balanceOf(user), userCtUSDBefore);
        assertEq(mockSwapRouter.swapCount(), 0);
    }

    function test_claimPayoutWithSwap_worksWhilePaused() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        _settleMarket(2);
        _warpToClaimOpen();

        vm.prank(owner);
        sys.core.pause();

        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        router.claimPayoutWithSwap(positionId, address(inputToken), 1);

        assertFalse(sys.position.exists(positionId));
        assertGt(inputToken.balanceOf(user), userInputBefore);
        assertEq(mockSwapRouter.swapCount(), 1);
    }

    function test_claimPayoutWithSwap_losingClaimSkipsSwap() public {
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        _settleMarket(10);
        _warpToClaimOpen();

        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        router.claimPayoutWithSwap(positionId, address(inputToken), 0);

        assertFalse(sys.position.exists(positionId));
        assertEq(inputToken.balanceOf(user), userInputBefore);
        assertEq(mockSwapRouter.swapCount(), 0);
    }

    function test_openPositionWithSwap_revertsWhenSwapSlippageExceedsMinCtUSD() public {
        _allowToken(address(inputToken));

        uint256 inputAmount = 25_000;
        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MockAlgebraSwapRouter.OutputBelowMinimum.selector, inputAmount, inputAmount + 1)
        );
        router.openPositionWithSwap(
            address(inputToken),
            inputAmount,
            inputAmount + 1,
            marketId,
            LOWER_TICK,
            UPPER_TICK,
            POSITION_QTY,
            inputAmount + 1
        );

        assertEq(inputToken.balanceOf(user), userInputBefore);
        assertEq(sys.position.nextId(), 1);
        assertEq(mockSwapRouter.swapCount(), 0);
    }

    function test_openPositionWithSwap_revertsAndRollsBackWhenBetCostExceedsSwapOutput() public {
        _allowToken(address(inputToken));

        uint256 openCost = sys.core.calculateOpenCost(marketId, LOWER_TICK, UPPER_TICK, POSITION_QTY);
        uint256 inputAmount = openCost - 1;
        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        vm.expectRevert();
        router.openPositionWithSwap(
            address(inputToken),
            inputAmount,
            1,
            marketId,
            LOWER_TICK,
            UPPER_TICK,
            POSITION_QTY,
            openCost + 1
        );

        assertEq(inputToken.balanceOf(user), userInputBefore);
        assertEq(sys.position.nextId(), 1);
        assertEq(sys.payment.balanceOf(address(router)), 0);
        assertEq(mockSwapRouter.swapCount(), 0);
    }

    function test_openPositionWithSwap_revertsForTokenNotAllowed() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SignalsRouter.TokenNotAllowed.selector, address(inputToken)));
        router.openPositionWithSwap(address(inputToken), 1, 1, marketId, LOWER_TICK, UPPER_TICK, POSITION_QTY, 1);
    }

    function test_setAllowedToken_revertsForCtUSD() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SignalsRouter.TokenNotAllowed.selector, address(sys.payment)));
        router.setAllowedToken(address(sys.payment), true);
    }

    function test_openPositionWithSwap_revertsForZeroInputAmount() public {
        _allowToken(address(inputToken));

        vm.prank(user);
        vm.expectRevert(SignalsRouter.InvalidAmount.selector);
        router.openPositionWithSwap(address(inputToken), 0, 1, marketId, LOWER_TICK, UPPER_TICK, POSITION_QTY, 1);
    }

    function test_openPositionWithSwap_revertsWhenMarketExpired() public {
        _allowToken(address(inputToken));

        uint256 openCost = sys.core.calculateOpenCost(marketId, LOWER_TICK, UPPER_TICK, POSITION_QTY);
        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.warp(block.timestamp + 51);

        vm.prank(user);
        vm.expectRevert();
        router.openPositionWithSwap(
            address(inputToken),
            openCost,
            openCost,
            marketId,
            LOWER_TICK,
            UPPER_TICK,
            POSITION_QTY,
            openCost + 1
        );

        assertEq(inputToken.balanceOf(user), userInputBefore);
        assertEq(sys.position.nextId(), 1);
        assertEq(mockSwapRouter.swapCount(), 0);
    }

    function test_positionOperationsWithSwap_revertWithoutNftApproval() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);
        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        vm.expectRevert();
        router.increasePositionWithSwap(positionId, address(inputToken), 25_000, 25_000, INCREASE_QTY, 25_000);

        vm.prank(user);
        vm.expectRevert();
        router.decreasePositionWithSwap(positionId, POSITION_QTY / 2, address(sys.payment), 0, 0);

        assertEq(sys.position.ownerOf(positionId), user);
        assertEq(sys.position.getPosition(positionId).quantity, POSITION_QTY);
        assertEq(inputToken.balanceOf(user), userInputBefore);
    }

    function test_increasePositionWithSwap_emitsActualOwnerWithoutRouterTransfer() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);
        uint256 quotedCost = sys.core.calculateIncreaseCost(positionId, INCREASE_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        vm.recordLogs();

        vm.expectEmit(true, true, false, true, address(sys.core));
        emit TradeModule.PositionIncreased(positionId, user, INCREASE_QTY, POSITION_QTY + INCREASE_QTY, quotedCost);

        vm.prank(user);
        router.increasePositionWithSwap(positionId, address(inputToken), 25_000, 25_000, INCREASE_QTY, 25_000);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertNoRouterTransfers(entries);
    }

    function test_decreasePositionWithSwap_revertsWhenCallerIsNotPositionOwner() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);
        address attacker = sys.users[1];

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SE.UnauthorizedCaller.selector, attacker));
        router.decreasePositionWithSwap(positionId, POSITION_QTY / 2, address(sys.payment), 0, 0);
    }

    function test_decreasePositionWithSwap_emitsActualOwnerWithoutRouterTransfer() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);
        uint128 sellQty = POSITION_QTY / 2;
        uint256 quotedProceeds = sys.core.calculateDecreaseProceeds(positionId, sellQty);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        vm.recordLogs();

        vm.expectEmit(true, true, false, true, address(sys.core));
        emit TradeModule.PositionDecreased(positionId, user, sellQty, POSITION_QTY - sellQty, quotedProceeds);

        vm.prank(user);
        router.decreasePositionWithSwap(positionId, sellQty, address(inputToken), 1, 0);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertNoRouterTransfers(entries);
    }

    function test_decreasePositionWithSwap_revertsWhenMinProceedsNotMet() public {
        uint256 positionId = _openDirectPosition(POSITION_QTY);
        uint256 quotedProceeds = sys.core.calculateDecreaseProceeds(positionId, POSITION_QTY / 2);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        vm.prank(user);
        vm.expectRevert();
        router.decreasePositionWithSwap(positionId, POSITION_QTY / 2, address(sys.payment), 0, quotedProceeds + 1);

        assertEq(sys.position.ownerOf(positionId), user);
        assertEq(sys.position.getPosition(positionId).quantity, POSITION_QTY);
        assertEq(mockSwapRouter.swapCount(), 0);
    }

    function test_onERC721Received_rejectsNonMintTransfer() public {
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        vm.expectRevert(SignalsRouter.UnexpectedNFT.selector);
        sys.position.safeTransferFrom(user, address(router), positionId);
    }

    function test_setAllowedToken_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, user));
        router.setAllowedToken(address(inputToken), true);
    }

    function test_rescueToken_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, user));
        router.rescueToken(address(inputToken), user, 1);
    }

    function test_rescueNFT_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(0x118cdaa7, user));
        router.rescueNFT(address(sys.position), user, 1);
    }

    function test_ownerCanRescueStuckNftAndTokenDust() public {
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.transferFrom(user, address(router), positionId);

        inputToken.mint(address(router), RESCUE_DUST);
        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.startPrank(owner);
        router.rescueNFT(address(sys.position), user, positionId);
        router.rescueToken(address(inputToken), user, RESCUE_DUST);
        vm.stopPrank();

        assertEq(sys.position.ownerOf(positionId), user);
        assertEq(inputToken.balanceOf(user), userInputBefore + RESCUE_DUST);
    }

    function test_closePositionWithSwap_swapsProceedsToOutputToken() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        router.closePositionWithSwap(positionId, address(inputToken), 1, 0);

        assertFalse(sys.position.exists(positionId));
        assertGt(inputToken.balanceOf(user), userInputBefore);
        assertEq(mockSwapRouter.swapCount(), 1);
    }

    function test_decreasePositionWithSwap_fullQuantityBurnsNft() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        router.decreasePositionWithSwap(positionId, POSITION_QTY, address(inputToken), 1, 0);

        assertFalse(sys.position.exists(positionId));
        assertGt(inputToken.balanceOf(user), userInputBefore);
        assertEq(mockSwapRouter.swapCount(), 1);
    }

    function test_claimPayoutWithSwap_winningClaimSwapsProceedsToUser() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        _settleMarket(2);
        _warpToClaimOpen();

        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        router.claimPayoutWithSwap(positionId, address(inputToken), 1);

        assertFalse(sys.position.exists(positionId));
        assertGt(inputToken.balanceOf(user), userInputBefore);
        assertEq(mockSwapRouter.swapCount(), 1);
    }

    function test_decreasePositionWithSwap_keepsPreExistingCtUSDDustInRouter() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);
        uint256 quotedProceeds = sys.core.calculateDecreaseProceeds(positionId, POSITION_QTY / 2);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        sys.payment.mint(address(router), ROUTER_DUST);
        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        router.decreasePositionWithSwap(positionId, POSITION_QTY / 2, address(inputToken), 1, 0);

        assertEq(sys.payment.balanceOf(address(router)), ROUTER_DUST);
        assertEq(inputToken.balanceOf(user), userInputBefore + quotedProceeds);
        assertEq(sys.position.ownerOf(positionId), user);
        assertEq(sys.position.getPosition(positionId).quantity, POSITION_QTY / 2);
    }

    function test_claimPayoutWithSwap_keepsPreExistingCtUSDDustInRouter() public {
        _allowToken(address(inputToken));
        uint256 positionId = _openDirectPosition(POSITION_QTY);

        vm.prank(user);
        sys.position.setApprovalForAll(address(router), true);

        _settleMarket(2);
        _warpToClaimOpen();

        sys.payment.mint(address(router), ROUTER_DUST);
        uint256 userInputBefore = inputToken.balanceOf(user);

        vm.prank(user);
        router.claimPayoutWithSwap(positionId, address(inputToken), 1);

        assertFalse(sys.position.exists(positionId));
        assertEq(sys.payment.balanceOf(address(router)), ROUTER_DUST);
        assertGt(inputToken.balanceOf(user), userInputBefore);
    }

    function test_constructor_revertsForZeroAddressParameters() public {
        vm.expectRevert(SignalsRouter.ZeroAddress.selector);
        new SignalsRouter(
            address(0),
            address(sys.position),
            address(sys.payment),
            address(mockSwapRouter),
            address(0),
            owner
        );

        vm.expectRevert(SignalsRouter.ZeroAddress.selector);
        new SignalsRouter(
            address(sys.core),
            address(0),
            address(sys.payment),
            address(mockSwapRouter),
            address(0),
            owner
        );

        vm.expectRevert(SignalsRouter.ZeroAddress.selector);
        new SignalsRouter(
            address(sys.core),
            address(sys.position),
            address(0),
            address(mockSwapRouter),
            address(0),
            owner
        );

        vm.expectRevert(SignalsRouter.ZeroAddress.selector);
        new SignalsRouter(
            address(sys.core),
            address(sys.position),
            address(sys.payment),
            address(0),
            address(0),
            owner
        );

        vm.expectRevert();
        new SignalsRouter(
            address(sys.core),
            address(sys.position),
            address(sys.payment),
            address(mockSwapRouter),
            address(0),
            address(0)
        );
    }

    function _allowToken(address token) internal {
        vm.prank(owner);
        router.setAllowedToken(token, true);
    }

    function _openDirectPosition(uint128 quantity) internal returns (uint256 positionId) {
        uint256 maxCost = sys.core.calculateOpenCost(marketId, LOWER_TICK, UPPER_TICK, quantity) + 1_000_000;
        positionId = sys.position.nextId();

        vm.prank(user);
        sys.core.openPosition(marketId, LOWER_TICK, UPPER_TICK, quantity, maxCost);
    }

    function _settleMarket(uint256 priceHuman) internal {
        SettlementHelper.settleMarket(vm, address(sys.core), owner, marketId, priceHuman);
    }

    function _warpToClaimOpen() internal {
        (, , , uint64 claimOpen) = sys.core.getSettlementWindows(marketId);
        vm.warp(claimOpen);
    }

    function _assertNoRouterTransfers(Vm.Log[] memory entries) internal view {
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        bytes32 routerTopic = bytes32(uint256(uint160(address(router))));

        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.emitter != address(sys.position) || entry.topics.length != 4 || entry.topics[0] != transferSig) {
                continue;
            }

            assertTrue(entry.topics[1] != routerTopic, "router should not send position NFT");
            assertTrue(entry.topics[2] != routerTopic, "router should not receive position NFT");
        }
    }
}
