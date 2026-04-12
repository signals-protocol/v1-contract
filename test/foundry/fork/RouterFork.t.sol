// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/ForkBaseTest.sol";
import "../../../contracts/interfaces/IAlgebraSwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RouterForkTest is ForkBaseTest {
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

    function test_exactInputSingle_selector_matches_canonical_signature() public pure {
        bytes4 expected = bytes4(
            keccak256("exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))")
        );
        assertEq(IAlgebraSwapRouter.exactInputSingle.selector, expected, "selector mismatch");
    }

    function test_exactInputSingle_executes_live_usdcE_to_ctUSD_swap() public {
        if (address(liveSwapRouter) == address(0)) return;

        address trader = makeAddr("trader");
        uint256 amountIn = 1e6;

        deal(address(usdcE), trader, amountIn);

        uint256 ctUSDBefore = ctUSDToken.balanceOf(trader);

        vm.startPrank(trader);
        usdcE.approve(address(liveSwapRouter), amountIn);

        uint256 amountOut = liveSwapRouter.exactInputSingle(
            IAlgebraSwapRouter.ExactInputSingleParams({
                tokenIn: address(usdcE),
                tokenOut: address(ctUSDToken),
                deployer: address(0),
                recipient: trader,
                deadline: block.timestamp + 600,
                amountIn: amountIn,
                amountOutMinimum: 1,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "swap returned zero");
        assertEq(ctUSDToken.balanceOf(trader), ctUSDBefore + amountOut, "ctUSD balance mismatch");
    }
}
