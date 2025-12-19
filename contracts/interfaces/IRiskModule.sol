// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRiskModule
/// @notice Interface for RiskModule gate functions
/// @dev Used by SignalsCore for abi.encodeCall in delegatecall
interface IRiskModule {
    /// @notice Gate for market creation - validates α limit and prior admissibility
    /// @param liquidityParameter Market α to validate (WAD)
    /// @param numBins Number of outcome bins
    /// @param baseFactors Prior factor weights
    function gateCreateMarket(
        uint256 liquidityParameter,
        uint32 numBins,
        uint256[] calldata baseFactors
    ) external view;

    /// @notice Gate for market reopen - re-validates α and prior
    /// @param liquidityParameter Market α to validate (WAD)
    /// @param numBins Number of outcome bins
    /// @param deltaEt Stored tail budget from market creation (WAD)
    function gateReopenMarket(
        uint256 liquidityParameter,
        uint32 numBins,
        uint256 deltaEt
    ) external view;

    /// @notice Gate for position open - validates exposure caps
    /// @param marketId Market ID
    /// @param trader Trader address
    /// @param quantity Position quantity
    function gateOpenPosition(
        uint256 marketId,
        address trader,
        uint128 quantity
    ) external view;

    /// @notice Gate for position increase - validates exposure caps
    /// @param positionId Position ID
    /// @param trader Trader address
    /// @param additionalQuantity Additional quantity
    function gateIncreasePosition(
        uint256 positionId,
        address trader,
        uint128 additionalQuantity
    ) external view;

    /// @notice Gate for withdrawal request - validates liquidity constraints
    /// @param user User requesting withdrawal
    /// @param shares Shares to withdraw
    function gateRequestWithdraw(
        address user,
        uint256 shares
    ) external view;
}

