// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ISignalsCore} from "../interfaces/ISignalsCore.sol";
import {ISignalsPosition} from "../interfaces/ISignalsPosition.sol";
import {IAlgebraSwapRouter} from "../interfaces/IAlgebraSwapRouter.sol";
import {SignalsErrors as SE} from "../errors/SignalsErrors.sol";

/// @title SignalsRouter
/// @notice Atomic swap-and-bet router for non-ctUSD tokens.
contract SignalsRouter is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    error InvalidAmount();
    error TokenNotAllowed(address token);
    error UnexpectedNFT();
    error ZeroAddress();

    event AllowedTokenUpdated(address indexed token, bool allowed);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event NFTRescued(address indexed token, address indexed to, uint256 tokenId);

    ISignalsCore public immutable core;
    ISignalsPosition public immutable positionNFT;
    IERC20 public immutable ctUSD;
    IAlgebraSwapRouter public immutable swapRouter;
    address public immutable poolDeployer;

    mapping(address => bool) public allowedTokens;

    constructor(
        address core_,
        address positionNFT_,
        address ctUSD_,
        address swapRouter_,
        address poolDeployer_,
        address owner_
    ) Ownable(owner_) {
        if (core_ == address(0) || positionNFT_ == address(0) || ctUSD_ == address(0) || swapRouter_ == address(0)) {
            revert ZeroAddress();
        }

        core = ISignalsCore(core_);
        positionNFT = ISignalsPosition(positionNFT_);
        ctUSD = IERC20(ctUSD_);
        swapRouter = IAlgebraSwapRouter(swapRouter_);
        poolDeployer = poolDeployer_;
    }

    function setAllowedToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (allowed && token == address(ctUSD)) revert TokenNotAllowed(token);
        allowedTokens[token] = allowed;
        emit AllowedTokenUpdated(token, allowed);
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function rescueNFT(address token, address to, uint256 tokenId) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC721(token).safeTransferFrom(address(this), to, tokenId);
        emit NFTRescued(token, to, tokenId);
    }

    function openPositionWithSwap(
        address inputToken,
        uint256 inputAmount,
        uint256 minCtUSD,
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 maxCost
    ) external nonReentrant returns (uint256 positionId) {
        _requireAmount(inputAmount);
        _requireAllowedToken(inputToken);

        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        uint256 ctUSDBefore = ctUSD.balanceOf(address(this));
        _swapExactInput(IERC20(inputToken), ctUSD, inputAmount, minCtUSD);
        uint256 ctUSDReceived = ctUSD.balanceOf(address(this)) - ctUSDBefore;
        ctUSD.forceApprove(address(core), ctUSDReceived);

        positionId = core.openPosition(marketId, lowerTick, upperTick, quantity, maxCost);

        uint256 ctUSDDelta = ctUSD.balanceOf(address(this)) - ctUSDBefore;
        if (ctUSDDelta > 0) {
            ctUSD.safeTransfer(msg.sender, ctUSDDelta);
        }

        IERC721(address(positionNFT)).safeTransferFrom(address(this), msg.sender, positionId);
    }

    function increasePositionWithSwap(
        uint256 positionId,
        address inputToken,
        uint256 inputAmount,
        uint256 minCtUSD,
        uint128 quantity,
        uint256 maxCost
    ) external nonReentrant {
        _requireAmount(inputAmount);
        _requireAllowedToken(inputToken);
        _requirePositionOwner(positionId);

        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        uint256 ctUSDBefore = ctUSD.balanceOf(address(this));
        _swapExactInput(IERC20(inputToken), ctUSD, inputAmount, minCtUSD);
        uint256 ctUSDReceived = ctUSD.balanceOf(address(this)) - ctUSDBefore;
        ctUSD.forceApprove(address(core), ctUSDReceived);

        core.increasePosition(positionId, quantity, maxCost);

        uint256 ctUSDDelta = ctUSD.balanceOf(address(this)) - ctUSDBefore;
        if (ctUSDDelta > 0) {
            ctUSD.safeTransfer(msg.sender, ctUSDDelta);
        }
    }

    function decreasePositionWithSwap(
        uint256 positionId,
        uint128 quantity,
        address outputToken,
        uint256 minOutputAmount,
        uint256 minProceeds
    ) external nonReentrant {
        _requirePositionOwner(positionId);

        uint256 ctUSDBefore = ctUSD.balanceOf(address(this));
        core.decreasePosition(positionId, quantity, minProceeds);
        uint256 receivedAmount = ctUSD.balanceOf(address(this)) - ctUSDBefore;

        _deliverOutput(outputToken, minOutputAmount, receivedAmount, msg.sender);
    }

    function closePositionWithSwap(
        uint256 positionId,
        address outputToken,
        uint256 minOutputAmount,
        uint256 minProceeds
    ) external nonReentrant {
        _requirePositionOwner(positionId);

        uint256 ctUSDBefore = ctUSD.balanceOf(address(this));
        core.closePosition(positionId, minProceeds);
        uint256 receivedAmount = ctUSD.balanceOf(address(this)) - ctUSDBefore;

        _deliverOutput(outputToken, minOutputAmount, receivedAmount, msg.sender);
    }

    function claimPayoutWithSwap(
        uint256 positionId,
        address outputToken,
        uint256 minOutputAmount
    ) external nonReentrant {
        _requirePositionOwner(positionId);

        uint256 ctUSDBefore = ctUSD.balanceOf(address(this));
        core.claimPayout(positionId);
        uint256 receivedAmount = ctUSD.balanceOf(address(this)) - ctUSDBefore;

        _deliverOutput(outputToken, minOutputAmount, receivedAmount, msg.sender);
    }

    function onERC721Received(address, address from, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(positionNFT) || from != address(0)) revert UnexpectedNFT();
        return this.onERC721Received.selector;
    }

    function _deliverOutput(
        address outputToken,
        uint256 minOutputAmount,
        uint256 receivedAmount,
        address recipient
    ) internal {
        if (receivedAmount == 0) return;

        if (outputToken == address(ctUSD)) {
            ctUSD.safeTransfer(recipient, receivedAmount);
            return;
        }

        _requireAllowedToken(outputToken);

        IERC20 outToken = IERC20(outputToken);
        uint256 outBefore = outToken.balanceOf(address(this));
        _swapExactInput(ctUSD, outToken, receivedAmount, minOutputAmount);
        uint256 outputAmount = outToken.balanceOf(address(this)) - outBefore;
        outToken.safeTransfer(recipient, outputAmount);
    }

    function _swapExactInput(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) internal returns (uint256 amountOut) {
        tokenIn.forceApprove(address(swapRouter), amountIn);
        amountOut = swapRouter.exactInputSingle(
            IAlgebraSwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                deployer: poolDeployer,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                limitSqrtPrice: 0
            })
        );
    }

    function _requirePositionOwner(uint256 positionId) internal view {
        if (positionNFT.ownerOf(positionId) != msg.sender) revert SE.UnauthorizedCaller(msg.sender);
    }

    function _requireAllowedToken(address token) internal view {
        if (!allowedTokens[token]) revert TokenNotAllowed(token);
    }

    function _requireAmount(uint256 amount) internal pure {
        if (amount == 0) revert InvalidAmount();
    }
}
