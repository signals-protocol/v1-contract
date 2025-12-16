// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/ISignalsCore.sol";
import "../../interfaces/ISignalsPosition.sol";
import "../../lib/LazyMulSegmentTree.sol";

abstract contract SignalsCoreStorage {
    /// @dev Batch/day granularity for daily accounting. Used to derive batchId as day-key.
    ///      Note: This is a mechanism-layer constant (whitepaper "day t" cycle).
    uint64 internal constant BATCH_SECONDS = 86_400;

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

    // ============================================================
    // Phase 5: Fee Waterfall & Capital Stack
    // ============================================================

    /// @notice Capital stack configuration (Backstop + Treasury)
    struct CapitalStackState {
        uint256 backstopNav;     // B_t: Backstop NAV (WAD)
        uint256 treasuryNav;     // T_t: Treasury NAV (WAD)
    }

    /// @notice Fee waterfall configuration parameters
    struct FeeWaterfallConfig {
        int256 pdd;              // Drawdown floor (negative WAD, e.g., -0.3e18 = -30%)
        uint256 rhoBS;           // ρ_BS: Backstop coverage target ratio (WAD)
        uint256 phiLP;           // ϕ_LP: LP residual fee share (WAD)
        uint256 phiBS;           // ϕ_BS: Backstop residual fee share (WAD)
        uint256 phiTR;           // ϕ_TR: Treasury residual fee share (WAD)
        uint256 deltaEt;         // ΔEₜ: Tail budget (WAD). V1: 0 (uniform prior)
                                 // Per WP v2: ΔEₜ := E_ent(q₀,t) - α_t ln n
                                 // Uniform prior → ΔEₜ = 0 (no tail risk)
    }

    /// @notice Daily P&L snapshot for batch processing
    /// @dev Fields match whitepaper Appendix A naming for easy verification
    struct DailyPnlSnapshot {
        // Input values
        int256 Lt;               // CLMSR P&L (signed)
        uint256 Ftot;            // Total gross fees
        
        // Fee Waterfall intermediate values
        uint256 Floss;           // Loss compensation: min(Ftot, |L^-|)
        uint256 Fpool;           // Remaining pool: Ftot - Floss
        uint256 Nraw;            // NAV after loss comp: N_{t-1} + Lt + Floss
        uint256 Gt;              // Grant from Backstop
        uint256 Ffill;           // Backstop coverage fill
        
        // Fee splits
        uint256 FLP;             // Fee to LP: Floss + F_core_LP + dust
        uint256 FBS;             // Fee to Backstop: F_fill + F_core_BS
        uint256 FTR;             // Fee to Treasury: F_core_TR
        uint256 Fdust;           // Rounding dust (to LP)
        
        // Output values
        uint256 Ft;              // Total fee credited to LP NAV
        uint256 Npre;            // Pre-batch NAV
        uint256 Pe;              // Batch equity price: Npre / S_{t-1}
        
        // State
        bool processed;          // Whether this batch has been processed
    }

    /// @notice Unified capital stack state (Phase 5)
    CapitalStackState internal capitalStack;

    /// @notice Fee waterfall configuration (Phase 5)
    FeeWaterfallConfig internal feeWaterfallConfig;

    /// @notice Daily P&L snapshots by batch ID
    mapping(uint64 => DailyPnlSnapshot) internal _dailyPnl;

    // ============================================================
    // Phase 6: Request ID-based Queue (Placeholder)
    // ============================================================

    /// @notice Request status enum for ID-based queue (Phase 6)
    enum RequestStatus {
        Pending,
        Processed,
        Claimed,
        Cancelled
    }

    /// @notice Deposit request with ID (Phase 6)
    struct DepositRequest {
        uint64 id;
        address owner;
        uint256 amount;
        uint64 eligibleBatchId;
        RequestStatus status;
    }

    /// @notice Withdraw request with ID (Phase 6)
    struct WithdrawRequest {
        uint64 id;
        address owner;
        uint256 shares;
        uint64 eligibleBatchId;
        RequestStatus status;
    }

    /// @notice Batch aggregation result (Phase 6)
    struct BatchAggregation {
        uint256 totalDepositAssets;   // Sum of all eligible deposit amounts
        uint256 totalWithdrawShares;  // Sum of all eligible withdraw shares
        uint256 batchPrice;           // P^e_t used for this batch
        bool processed;               // Whether batch has been processed
    }

    /// @notice Pending aggregation for batch (pre-processing)
    struct PendingBatchTotal {
        uint256 deposits;    // Sum of pending deposit amounts for this batch
        uint256 withdraws;   // Sum of pending withdraw shares for this batch
    }

    // ============================================================
    // Phase 6: Request ID-based Queue Storage (Active)
    // ============================================================

    /// @notice Request ID → DepositRequest mapping
    mapping(uint64 => DepositRequest) internal _depositRequests;

    /// @notice Request ID → WithdrawRequest mapping
    mapping(uint64 => WithdrawRequest) internal _withdrawRequests;

    /// @notice Batch ID → Aggregation result (post-processing)
    mapping(uint64 => BatchAggregation) internal _batchAggregations;

    /// @notice Batch ID → Pending totals (pre-processing)
    /// @dev Used for O(1) batch processing: totals are pre-aggregated on request
    mapping(uint64 => PendingBatchTotal) internal _pendingBatchTotals;

    /// @notice Next deposit request ID
    uint64 public nextDepositRequestId;

    /// @notice Next withdraw request ID
    uint64 public nextWithdrawRequestId;

    /// @notice Current batch ID (increments on each batch)
    uint64 public currentBatchId;

    /// @notice Withdrawal lag in batches (D_lag)
    /// @dev Request made at batch N is eligible at batch N + withdrawalLagBatches
    uint64 public withdrawalLagBatches;

    // ============================================================
    // Phase 6: Exposure Ledger & Payout Reserve
    // ============================================================

    /// @notice Market ID → (tick index → exposure amount in token units)
    /// @dev Exposure Ledger Q_t: tracks payout liability per settlement tick
    ///      Q_{t,b} = total payout owed if settlement tick τ_t = b
    ///      Open/increase: adds quantity to [lowerTick, upperTick) range
    ///      Decrease/close: subtracts quantity from [lowerTick, upperTick) range
    mapping(uint256 => mapping(int256 => uint256)) internal _exposureLedger;

    /// @notice Market ID → payout reserve (escrow) for settled markets
    /// @dev Set at settleMarket time, equals Q_{τ_t} (exposure at settlement tick)
    ///      Subsequent claims draw from this reserve without affecting NAV
    mapping(uint256 => uint256) internal _payoutReserve;

    /// @notice Market ID → remaining payout reserve (decremented on each claim)
    mapping(uint256 => uint256) internal _payoutReserveRemaining;

    // ============================================================
    // Phase 6: Free Balance Accounting (Escrow Safety)
    // ============================================================

    /// @notice Total pending deposits in 6-decimal token units
    /// @dev Incremented on requestDeposit, decremented on cancelDeposit or processDailyBatch
    ///      Used for free balance calculation to ensure deposit funds are isolated
    uint256 internal _totalPendingDeposits6;

    /// @notice Total payout reserve in 6-decimal token units
    /// @dev Sum of all _payoutReserveRemaining across all markets
    ///      Incremented at settlement, decremented on claimPayout
    uint256 internal _totalPayoutReserve6;

    // ============================================================
    // Phase 7: Risk Configuration
    // ============================================================

    /// @notice Risk parameters for α Safety Bounds (WP v2 Sec 4.3-4.5)
    struct RiskConfig {
        uint256 lambda;      // λ: Safety parameter (WAD), e.g., 0.3e18 = 30% max drawdown
        uint256 kDrawdown;   // k: Drawdown sensitivity factor (WAD), typically 1.0e18
        bool enforceAlpha;   // Whether to enforce α bounds at market config time (create/reopen)
    }

    /// @notice Risk configuration (Phase 7)
    RiskConfig internal riskConfig;

    // Reserve ample slots for future upgrades; do not change after first deployment.
    uint256[14] internal __gap;
}
