// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/ISignalsCore.sol";
import "../../interfaces/ISignalsPosition.sol";
import "../../lib/LazyMulSegmentTree.sol";

abstract contract SignalsCoreStorage {
    // Governance-configurable settlement windows (set via initializer/setter in Core).
    uint64 public settlementSubmitWindow;
    uint64 public settlementFinalizeDeadline;

    IERC20 public paymentToken;
    ISignalsPosition public positionContract;

    mapping(uint256 => ISignalsCore.Market) public markets;
    mapping(uint256 => LazyMulSegmentTree.Tree) public marketTrees;
    uint256 public nextMarketId;

    struct SettlementOracleState {
        int256 candidateValue;
        uint64 candidatePriceTimestamp;
    }

    mapping(uint256 => SettlementOracleState) internal settlementOracleState;
    address public settlementOracleSigner;

    mapping(uint256 => bool) public positionSettledEmitted;

    address public feeRecipient;
    address public defaultFeePolicy;

    // ============================================================
    // LP Vault State (Phase 4)
    // ============================================================
    
    /// @notice LP Vault accounting state
    struct VaultState {
        uint256 nav;           // N_t: current NAV (WAD)
        uint256 shares;        // S_t: current total shares (WAD)
        uint256 price;         // P_t: current price (WAD)
        uint256 pricePeak;     // P^peak_t: running peak price (WAD)
        uint64 lastBatchTimestamp; // Timestamp of last batch
        bool isSeeded;         // Has vault been seeded
    }
    
    /// @notice Backstop vault state
    struct BackstopState {
        uint256 nav;           // B_t: Backstop NAV (WAD)
        uint256 targetCoverage; // ρ_BS target coverage ratio (WAD)
    }

    /// @notice Treasury state
    struct TreasuryState {
        uint256 nav;           // T_t: Treasury NAV (WAD)
    }

    /// @notice User deposit/withdraw request
    struct VaultRequest {
        uint256 amount;        // Deposit: asset amount, Withdraw: shares
        uint64 requestTimestamp;
        bool isDeposit;        // true = deposit, false = withdraw
    }

    /// @notice Pending queue totals
    struct VaultQueue {
        uint256 pendingDeposits;    // Total pending deposit amount (WAD)
        uint256 pendingWithdraws;   // Total pending withdraw shares (WAD)
    }

    VaultState internal lpVault;
    BackstopState internal backstop;
    TreasuryState internal treasury;
    VaultQueue internal vaultQueue;

    /// @notice User request queue: user => request
    mapping(address => VaultRequest) internal userRequests;

    /// @notice Withdrawal lag in seconds
    uint64 public withdrawLag;

    /// @notice Minimum seed amount for first deposit
    uint256 public minSeedAmount;

    /// @notice Fee distribution ratios (must sum to WAD)
    uint256 public feeRatioLP;      // ϕ_LP
    uint256 public feeRatioBackstop; // ϕ_BS
    uint256 public feeRatioTreasury; // ϕ_TR

    // Reserve ample slots for future upgrades; do not change after first deployment.
    uint256[35] internal __gap;
}
