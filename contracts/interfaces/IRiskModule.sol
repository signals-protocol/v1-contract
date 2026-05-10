// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IRiskModule
/// @notice Interface for the RiskModule createMarket gate
/// @dev Used by SignalsCore for abi.encodeCall in delegatecall
interface IRiskModule {
    /// @notice Gate for market creation - validates α limit and prior admissibility
    /// @param liquidityParameter Market α to validate (WAD)
    /// @param numBins Number of outcome bins
    /// @param seedData Address of SeedData contract containing factors
    function gateCreateMarket(uint256 liquidityParameter, uint32 numBins, address seedData) external view;
}
