// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../modules/LPVaultModule.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LPVaultModuleProxy
 * @notice Test harness to delegate calls to LPVaultModule
 * @dev Provides storage context for delegate calls
 */
contract LPVaultModuleProxy is SignalsCoreStorage {
    address public module;

    constructor(address _module) {
        module = _module;
    }

    // ============================================================
    // Setup
    // ============================================================

    function setPaymentToken(address token) external {
        paymentToken = IERC20(token);
    }

    function setMinSeedAmount(uint256 amount) external {
        minSeedAmount = amount;
    }

    function setWithdrawLag(uint64 lag) external {
        withdrawLag = lag;
    }

    // ============================================================
    // Delegated calls
    // ============================================================

    function seedVault(uint256 seedAmount) external {
        _delegate(abi.encodeWithSelector(LPVaultModule.seedVault.selector, seedAmount));
    }

    function requestDeposit(uint256 amount) external {
        _delegate(abi.encodeWithSelector(LPVaultModule.requestDeposit.selector, amount));
    }

    function requestWithdraw(uint256 shares) external {
        _delegate(abi.encodeWithSelector(LPVaultModule.requestWithdraw.selector, shares));
    }

    function cancelDeposit() external {
        _delegate(abi.encodeWithSelector(LPVaultModule.cancelDeposit.selector));
    }

    function cancelWithdraw() external {
        _delegate(abi.encodeWithSelector(LPVaultModule.cancelWithdraw.selector));
    }

    function processBatch(int256 pnl, uint256 fees, uint256 grant) external {
        _delegate(abi.encodeWithSelector(
            LPVaultModule.processBatch.selector,
            pnl,
            fees,
            grant
        ));
    }

    // ============================================================
    // View functions (direct storage reads)
    // ============================================================

    function getVaultNav() external view returns (uint256) {
        return lpVault.nav;
    }

    function getVaultShares() external view returns (uint256) {
        return lpVault.shares;
    }

    function getVaultPrice() external view returns (uint256) {
        return lpVault.price;
    }

    function getVaultPricePeak() external view returns (uint256) {
        return lpVault.pricePeak;
    }

    function isVaultSeeded() external view returns (bool) {
        return lpVault.isSeeded;
    }

    function getPendingTotals() external view returns (
        uint256 pendingDeposits,
        uint256 pendingWithdraws
    ) {
        return (vaultQueue.pendingDeposits, vaultQueue.pendingWithdraws);
    }

    function getUserRequest(address user) external view returns (
        uint256 amount,
        uint64 requestTimestamp,
        bool isDeposit
    ) {
        VaultRequest storage req = userRequests[user];
        return (req.amount, req.requestTimestamp, req.isDeposit);
    }

    // ============================================================
    // Internal
    // ============================================================

    function _delegate(bytes memory data) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = module.delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

