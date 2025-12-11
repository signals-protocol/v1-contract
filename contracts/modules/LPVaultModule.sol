// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/storage/SignalsCoreStorage.sol";
import "../vault/lib/VaultAccountingLib.sol";
import "../errors/ModuleErrors.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LPVaultModule
 * @notice Delegate-only module for LP Vault operations
 * @dev Phase 4 implementation - no Risk enforcement yet
 *
 * Implements:
 * - Deposit/withdraw request queue
 * - Daily batch processing
 * - NAV/shares/price updates per whitepaper Section 3
 */
contract LPVaultModule is SignalsCoreStorage {
    using SafeERC20 for IERC20;
    using VaultAccountingLib for *;

    address private immutable self;

    // ============================================================
    // Events
    // ============================================================
    event DepositRequested(address indexed user, uint256 amount, uint64 timestamp);
    event WithdrawRequested(address indexed user, uint256 shares, uint64 timestamp);
    event DepositCancelled(address indexed user, uint256 amount);
    event WithdrawCancelled(address indexed user, uint256 shares);
    event BatchProcessed(
        uint256 indexed batchId,
        uint256 navPre,
        uint256 batchPrice,
        uint256 navPost,
        uint256 sharesPost,
        uint256 pricePost
    );
    event VaultSeeded(address indexed seeder, uint256 amount, uint256 shares);

    // ============================================================
    // Errors
    // ============================================================
    error NotDelegated();
    error VaultNotSeeded();
    error VaultAlreadySeeded();
    error InsufficientSeedAmount(uint256 provided, uint256 required);
    error NoPendingRequest();
    error RequestLagNotMet(uint64 requestTime, uint64 requiredTime);
    error InsufficientShareBalance(uint256 requested, uint256 available);
    error ZeroAmount();
    error BatchAlreadyProcessed();

    // ============================================================
    // Modifiers
    // ============================================================
    modifier onlyDelegated() {
        if (address(this) == self) revert NotDelegated();
        _;
    }

    constructor() {
        self = address(this);
    }

    // ============================================================
    // Seeding
    // ============================================================

    /**
     * @notice Seed the vault with initial capital
     * @dev Must be called before any batch processing
     * @param seedAmount Initial deposit amount
     */
    function seedVault(uint256 seedAmount) external onlyDelegated {
        if (lpVault.isSeeded) revert VaultAlreadySeeded();
        if (seedAmount < minSeedAmount) {
            revert InsufficientSeedAmount(seedAmount, minSeedAmount);
        }

        // Transfer tokens from sender
        paymentToken.safeTransferFrom(msg.sender, address(this), seedAmount);

        // Initialize vault: 1:1 ratio at genesis
        lpVault.nav = seedAmount;
        lpVault.shares = seedAmount;
        lpVault.price = VaultAccountingLib.WAD;
        lpVault.pricePeak = VaultAccountingLib.WAD;
        lpVault.lastBatchTimestamp = uint64(block.timestamp);
        lpVault.isSeeded = true;

        emit VaultSeeded(msg.sender, seedAmount, seedAmount);
    }

    // ============================================================
    // Request Queue
    // ============================================================

    /**
     * @notice Request a deposit into the vault
     * @param amount Amount to deposit (will be transferred immediately)
     */
    function requestDeposit(uint256 amount) external onlyDelegated {
        if (amount == 0) revert ZeroAmount();
        if (!lpVault.isSeeded) revert VaultNotSeeded();

        // Transfer tokens immediately (held until batch)
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);

        // Record request
        VaultRequest storage req = userRequests[msg.sender];
        
        // If user has existing request, add to it
        if (req.isDeposit && req.amount > 0) {
            req.amount += amount;
        } else {
            // New request or convert from withdraw
            if (!req.isDeposit && req.amount > 0) {
                // User has pending withdraw - cannot have both
                revert NoPendingRequest(); // TODO: better error
            }
            req.amount = amount;
            req.requestTimestamp = uint64(block.timestamp);
            req.isDeposit = true;
        }

        // Update queue totals
        vaultQueue.pendingDeposits += amount;

        emit DepositRequested(msg.sender, amount, uint64(block.timestamp));
    }

    /**
     * @notice Request a withdrawal from the vault
     * @param shares Number of shares to withdraw
     */
    function requestWithdraw(uint256 shares) external onlyDelegated {
        if (shares == 0) revert ZeroAmount();
        if (!lpVault.isSeeded) revert VaultNotSeeded();

        // TODO: Check user share balance (requires LP share token integration)
        // For now, just track the request

        VaultRequest storage req = userRequests[msg.sender];
        
        if (!req.isDeposit && req.amount > 0) {
            req.amount += shares;
        } else {
            if (req.isDeposit && req.amount > 0) {
                revert NoPendingRequest(); // TODO: better error
            }
            req.amount = shares;
            req.requestTimestamp = uint64(block.timestamp);
            req.isDeposit = false;
        }

        vaultQueue.pendingWithdraws += shares;

        emit WithdrawRequested(msg.sender, shares, uint64(block.timestamp));
    }

    /**
     * @notice Cancel a pending deposit request
     */
    function cancelDeposit() external onlyDelegated {
        VaultRequest storage req = userRequests[msg.sender];
        if (!req.isDeposit || req.amount == 0) revert NoPendingRequest();

        uint256 amount = req.amount;
        
        // Clear request
        req.amount = 0;
        req.requestTimestamp = 0;

        // Update queue
        vaultQueue.pendingDeposits -= amount;

        // Return tokens
        paymentToken.safeTransfer(msg.sender, amount);

        emit DepositCancelled(msg.sender, amount);
    }

    /**
     * @notice Cancel a pending withdrawal request
     */
    function cancelWithdraw() external onlyDelegated {
        VaultRequest storage req = userRequests[msg.sender];
        if (req.isDeposit || req.amount == 0) revert NoPendingRequest();

        uint256 shares = req.amount;

        // Clear request
        req.amount = 0;
        req.requestTimestamp = 0;

        // Update queue
        vaultQueue.pendingWithdraws -= shares;

        // TODO: Restore shares to user (requires LP share token)

        emit WithdrawCancelled(msg.sender, shares);
    }

    // ============================================================
    // Batch Processing
    // ============================================================

    /**
     * @notice Process daily batch
     * @dev Applies P&L, then processes withdrawals, then deposits
     * @param pnl CLMSR P&L for the day (signed, WAD)
     * @param fees LP-attributed fees (WAD)
     * @param grant Backstop grant (WAD)
     */
    function processBatch(
        int256 pnl,
        uint256 fees,
        uint256 grant
    ) external onlyDelegated {
        if (!lpVault.isSeeded) revert VaultNotSeeded();

        // Step 1: Compute pre-batch NAV and price
        VaultAccountingLib.PreBatchInputs memory inputs = VaultAccountingLib.PreBatchInputs({
            navPrev: lpVault.nav,
            sharesPrev: lpVault.shares,
            pnl: pnl,
            fees: fees,
            grant: grant
        });

        VaultAccountingLib.PreBatchResult memory preBatch = VaultAccountingLib.computePreBatch(inputs);

        // Step 2: Process withdrawals first (at batch price)
        uint256 currentNav = preBatch.navPre;
        uint256 currentShares = lpVault.shares;

        if (vaultQueue.pendingWithdraws > 0) {
            (currentNav, currentShares, ) = VaultAccountingLib.applyWithdraw(
                currentNav,
                currentShares,
                preBatch.batchPrice,
                vaultQueue.pendingWithdraws
            );
            vaultQueue.pendingWithdraws = 0;
        }

        // Step 3: Process deposits (at batch price)
        if (vaultQueue.pendingDeposits > 0) {
            (currentNav, currentShares, ) = VaultAccountingLib.applyDeposit(
                currentNav,
                currentShares,
                preBatch.batchPrice,
                vaultQueue.pendingDeposits
            );
            vaultQueue.pendingDeposits = 0;
        }

        // Step 4: Compute final state
        VaultAccountingLib.PostBatchState memory postBatch = VaultAccountingLib.computePostBatchState(
            currentNav,
            currentShares,
            lpVault.pricePeak
        );

        // Step 5: Update storage
        lpVault.nav = postBatch.nav;
        lpVault.shares = postBatch.shares;
        lpVault.price = postBatch.price;
        lpVault.pricePeak = postBatch.pricePeak;
        lpVault.lastBatchTimestamp = uint64(block.timestamp);

        emit BatchProcessed(
            block.timestamp, // batchId = timestamp for now
            preBatch.navPre,
            preBatch.batchPrice,
            postBatch.nav,
            postBatch.shares,
            postBatch.price
        );
    }

    // ============================================================
    // View Functions
    // ============================================================

    /**
     * @notice Get vault NAV
     */
    function getVaultNav() external view returns (uint256) {
        return lpVault.nav;
    }

    /**
     * @notice Get vault shares
     */
    function getVaultShares() external view returns (uint256) {
        return lpVault.shares;
    }

    /**
     * @notice Get vault price
     */
    function getVaultPrice() external view returns (uint256) {
        return lpVault.price;
    }

    /**
     * @notice Check if vault is seeded
     */
    function isVaultSeeded() external view returns (bool) {
        return lpVault.isSeeded;
    }

    /**
     * @notice Get pending deposits total
     */
    function getPendingDeposits() external view returns (uint256) {
        return vaultQueue.pendingDeposits;
    }

    /**
     * @notice Get pending withdrawals total
     */
    function getPendingWithdraws() external view returns (uint256) {
        return vaultQueue.pendingWithdraws;
    }
}

