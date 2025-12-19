// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../errors/SignalsErrors.sol";

/// @title SignalsLPShare
/// @notice ERC-4626 compliant LP share token for Signals Protocol
/// @dev Adapts async batch model to ERC-4626 interface
///
///      Key differences from standard ERC-4626:
///      - deposit/mint → requestDeposit (returns 0, actual shares at claim)
///      - withdraw/redeem → requestWithdraw (returns 0, actual assets at claim)
///      - previewDeposit/previewRedeem → estimates at current batch price
///
///      The vault is the SignalsCore contract which holds actual NAV.
///      This token represents claims on the vault.
contract SignalsLPShare is ERC20, ERC20Permit, SignalsErrors, Ownable {
    /// @notice The SignalsCore contract that manages the vault
    address public immutable core;
    
    /// @notice The underlying asset (payment token, e.g., USDC)
    address public immutable asset;

    modifier onlyCore() {
        if (msg.sender != core) revert SignalsErrors.OnlyCore();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address core_,
        address asset_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(core_) {
        core = core_;
        asset = asset_;
    }

    // ============================================================
    // Core-only Mint/Burn (called by LPVaultModule via delegatecall)
    // ============================================================

    /// @notice Mint shares to user after deposit claim
    /// @dev Only callable by Core (via LPVaultModule delegatecall)
    /// @param to Recipient address
    /// @param shares Amount of shares to mint
    function mint(address to, uint256 shares) external onlyCore {
        _mint(to, shares);
    }

    /// @notice Burn shares from user after withdraw claim
    /// @dev Only callable by Core (via LPVaultModule delegatecall)
    /// @param from Address to burn from
    /// @param shares Amount of shares to burn
    function burn(address from, uint256 shares) external onlyCore {
        _burn(from, shares);
    }

    // ============================================================
    // ERC-4626 View Functions (Informational)
    // ============================================================

    /// @notice Returns the underlying asset
    function getAsset() external view returns (address) {
        return asset;
    }

    /// @notice Total assets under management
    /// @dev Returns vault NAV from Core
    function totalAssets() external view returns (uint256) {
        // Call Core to get NAV
        (bool success, bytes memory data) = core.staticcall(
            abi.encodeWithSignature("getVaultNav()")
        );
        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return 0;
    }

    /// @notice Convert assets to shares
    /// @dev Uses current batch price from Core
    function convertToShares(uint256 assets) external view returns (uint256) {
        uint256 price = _getVaultPrice();
        if (price == 0) return assets; // 1:1 if not seeded
        return (assets * 1e18) / price;
    }

    /// @notice Convert shares to assets
    /// @dev Uses current batch price from Core
    function convertToAssets(uint256 shares) external view returns (uint256) {
        uint256 price = _getVaultPrice();
        if (price == 0) return shares; // 1:1 if not seeded
        return (shares * price) / 1e18;
    }

    /// @notice Preview deposit - expected shares at current price
    /// @dev Note: Actual shares depend on batch price at claim time
    function previewDeposit(uint256 assets) external view returns (uint256) {
        uint256 price = _getVaultPrice();
        if (price == 0) return assets;
        return (assets * 1e18) / price;
    }

    /// @notice Preview redeem - expected assets at current price
    /// @dev Note: Actual assets depend on batch price at claim time
    function previewRedeem(uint256 shares) external view returns (uint256) {
        uint256 price = _getVaultPrice();
        if (price == 0) return shares;
        return (shares * price) / 1e18;
    }

    // ============================================================
    // ERC-4626 Deposit/Withdraw (Async - Reverts)
    // ============================================================

    /// @notice Standard deposit not supported - use requestDeposit on Core
    function deposit(uint256, address) external pure returns (uint256) {
        revert SignalsErrors.AsyncVaultUseRequestDeposit();
    }

    /// @notice Standard mint not supported - use requestDeposit on Core
    function mintShares(uint256, address) external pure returns (uint256) {
        revert SignalsErrors.AsyncVaultUseRequestDeposit();
    }

    /// @notice Standard withdraw not supported - use requestWithdraw on Core
    function withdraw(uint256, address, address) external pure returns (uint256) {
        revert SignalsErrors.AsyncVaultUseRequestWithdraw();
    }

    /// @notice Standard redeem not supported - use requestWithdraw on Core
    function redeem(uint256, address, address) external pure returns (uint256) {
        revert SignalsErrors.AsyncVaultUseRequestWithdraw();
    }

    // ============================================================
    // Internal Helpers
    // ============================================================

    /// @dev Get current vault price from Core
    function _getVaultPrice() internal view returns (uint256) {
        (bool success, bytes memory data) = core.staticcall(
            abi.encodeWithSignature("getVaultPrice()")
        );
        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return 1e18; // Default 1:1
    }
}

