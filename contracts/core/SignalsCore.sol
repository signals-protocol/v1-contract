// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./storage/SignalsCoreStorage.sol";
import "../interfaces/ISignalsCore.sol";
import "../interfaces/ISignalsPosition.sol";
import "../interfaces/IRiskModule.sol";
import "../errors/CLMSRErrors.sol";

/// @title SignalsCore
/// @notice Upgradeable entry core that holds storage and delegates to modules
contract SignalsCore is
    Initializable,
    ISignalsCore,
    SignalsCoreStorage,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 internal constant WAD = 1e18;

    address public tradeModule;
    address public lifecycleModule;
    address public riskModule;
    address public vaultModule;
    address public oracleModule;

    // ============================================================
    // Errors
    // ============================================================
    error ModuleNotSet();
    error InvalidFeeSplitSum(uint256 phiLP, uint256 phiBS, uint256 phiTR);

    // ============================================================
    // Events (Phase 10: Config changes for FE/Indexer)
    // ============================================================
    event RiskConfigUpdated(uint256 lambda, uint256 kDrawdown, bool enforceAlpha);
    event FeeWaterfallConfigUpdated(uint256 rhoBS, int256 pdd, uint256 phiLP, uint256 phiBS, uint256 phiTR);
    event CapitalStackUpdated(uint256 backstopNav, uint256 treasuryNav);
    event WithdrawalLagUpdated(uint64 lag);
    event LpShareTokenUpdated(address lpShareToken);
    event ModulesUpdated(address trade, address lifecycle, address risk, address vault, address oracle);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Core initializer
    function initialize(
        address _paymentToken,
        address _positionContract,
        uint64 _settlementSubmitWindow,
        uint64 _settlementFinalizeDeadline
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        paymentToken = IERC20(_paymentToken);
        positionContract = ISignalsPosition(_positionContract);
        settlementSubmitWindow = _settlementSubmitWindow;
        claimDelaySeconds = _settlementFinalizeDeadline;
    }

    /// @notice Set module addresses
    function setModules(
        address _tradeModule,
        address _lifecycleModule,
        address _riskModule,
        address _vaultModule,
        address _oracleModule
    ) external onlyOwner {
        tradeModule = _tradeModule;
        lifecycleModule = _lifecycleModule;
        riskModule = _riskModule;
        vaultModule = _vaultModule;
        oracleModule = _oracleModule;
        emit ModulesUpdated(_tradeModule, _lifecycleModule, _riskModule, _vaultModule, _oracleModule);
    }

    // ============================================================
    // Vault configuration (Phase 6)
    // ============================================================

    function setMinSeedAmount(uint256 amount) external onlyOwner whenNotPaused {
        if (amount == 0) revert CE.ZeroLimit();
        minSeedAmount = amount;
    }

    /// @notice Set LP Share token address (Phase 10: ERC-4626)
    function setLpShareToken(address _lpShareToken) external onlyOwner {
        lpShareToken = _lpShareToken;
        emit LpShareTokenUpdated(_lpShareToken);
    }

    function setWithdrawalLagBatches(uint64 lag) external onlyOwner whenNotPaused {
        withdrawalLagBatches = lag;
        emit WithdrawalLagUpdated(lag);
    }

    /// @notice Configure fee waterfall parameters (except pdd)
    /// @dev Per WP v2: pdd := -λ is enforced via setRiskConfig to maintain Safety invariant.
    ///      This function does NOT accept pdd parameter to prevent breaking the invariant.
    ///      Use setRiskConfig to change drawdown floor (via λ).
    function setFeeWaterfallConfig(
        uint256 rhoBS,
        uint256 phiLP,
        uint256 phiBS,
        uint256 phiTR
    ) external onlyOwner whenNotPaused {
        if (phiLP + phiBS + phiTR != WAD) revert InvalidFeeSplitSum(phiLP, phiBS, phiTR);
        // pdd is NOT set here - it's controlled by setRiskConfig (pdd := -λ)
        feeWaterfallConfig.rhoBS = rhoBS;
        feeWaterfallConfig.phiLP = phiLP;
        feeWaterfallConfig.phiBS = phiBS;
        feeWaterfallConfig.phiTR = phiTR;
        emit FeeWaterfallConfigUpdated(rhoBS, feeWaterfallConfig.pdd, phiLP, phiBS, phiTR);
    }

    function setCapitalStack(uint256 backstopNav, uint256 treasuryNav) external onlyOwner whenNotPaused {
        capitalStack.backstopNav = backstopNav;
        capitalStack.treasuryNav = treasuryNav;
        emit CapitalStackUpdated(backstopNav, treasuryNav);
    }

    /// @notice Configure risk parameters for α Safety Bounds
    /// @dev Per whitepaper v2: pdd := -λ (drawdown floor equals negative lambda)
    ///      This function enforces the relationship by auto-updating pdd when lambda is set.
    ///      WP v2: λ ∈ (0, 1) is required for safety invariants.
    /// @param lambda λ: Safety parameter (WAD), e.g., 0.3e18 = 30% max drawdown. Must be in (0, 1).
    /// @param kDrawdown k: Drawdown sensitivity factor (WAD), typically 1.0e18
    /// @param enforceAlpha Whether to enforce α bounds at market configuration time (create/reopen)
    function setRiskConfig(
        uint256 lambda,
        uint256 kDrawdown,
        bool enforceAlpha
    ) external onlyOwner whenNotPaused {
        // WP v2: λ must be in (0, 1) for safety invariants
        // λ = 0 would mean no drawdown limit (unsafe)
        // λ >= 1 would mean floor cannot be maintained (100%+ drop allowed is meaningless)
        if (lambda == 0 || lambda >= WAD) revert CE.InvalidLambda(lambda);

        riskConfig.lambda = lambda;
        riskConfig.kDrawdown = kDrawdown;
        riskConfig.enforceAlpha = enforceAlpha;
        
        // Whitepaper v2 invariant: pdd := -λ
        // Auto-update drawdown floor to maintain Safety guarantee
        feeWaterfallConfig.pdd = -int256(lambda);
        
        emit RiskConfigUpdated(lambda, kDrawdown, enforceAlpha);
    }

    // --- External stubs: delegate to modules ---

    function openPosition(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 maxCost
    ) external override whenNotPaused nonReentrant returns (uint256 positionId) {
        // Phase 8: Risk gate FIRST (no-op in Phase 8, exposure caps in Phase 9)
        _riskGate(abi.encodeCall(
            IRiskModule.gateOpenPosition,
            (marketId, msg.sender, quantity)
        ));

        bytes memory ret = _delegate(tradeModule, abi.encodeWithSignature(
            "openPosition(uint256,int256,int256,uint128,uint256)",
            marketId,
            lowerTick,
            upperTick,
            quantity,
            maxCost
        ));
        if (ret.length > 0) positionId = abi.decode(ret, (uint256));
    }

    function increasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 maxCost
    ) external override whenNotPaused nonReentrant {
        // Phase 8: Risk gate FIRST (no-op in Phase 8, exposure caps in Phase 9)
        _riskGate(abi.encodeCall(
            IRiskModule.gateIncreasePosition,
            (positionId, msg.sender, quantity)
        ));

        _delegate(tradeModule, abi.encodeWithSignature(
            "increasePosition(uint256,uint128,uint256)",
            positionId,
            quantity,
            maxCost
        ));
    }

    function decreasePosition(
        uint256 positionId,
        uint128 quantity,
        uint256 minProceeds
    ) external override whenNotPaused nonReentrant {
        _delegate(tradeModule, abi.encodeWithSignature(
            "decreasePosition(uint256,uint128,uint256)",
            positionId,
            quantity,
            minProceeds
        ));
    }

    function closePosition(
        uint256 positionId,
        uint256 minProceeds
    ) external override whenNotPaused nonReentrant {
        _delegate(tradeModule, abi.encodeWithSignature(
            "closePosition(uint256,uint256)",
            positionId,
            minProceeds
        ));
    }

    function claimPayout(uint256 positionId) external override whenNotPaused nonReentrant {
        _delegate(tradeModule, abi.encodeWithSignature("claimPayout(uint256)", positionId));
    }

    // ---- View stubs ----

    function calculateOpenCost(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity
    ) external override returns (uint256 cost) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculateOpenCost(uint256,int256,int256,uint128)",
            marketId,
            lowerTick,
            upperTick,
            quantity
        ));
        if (ret.length > 0) cost = abi.decode(ret, (uint256));
    }

    function calculateIncreaseCost(
        uint256 positionId,
        uint128 quantity
    ) external override returns (uint256 cost) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculateIncreaseCost(uint256,uint128)",
            positionId,
            quantity
        ));
        if (ret.length > 0) cost = abi.decode(ret, (uint256));
    }

    function calculateDecreaseProceeds(
        uint256 positionId,
        uint128 quantity
    ) external override returns (uint256 proceeds) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculateDecreaseProceeds(uint256,uint128)",
            positionId,
            quantity
        ));
        if (ret.length > 0) proceeds = abi.decode(ret, (uint256));
    }

    function calculateCloseProceeds(
        uint256 positionId
    ) external override returns (uint256 proceeds) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculateCloseProceeds(uint256)",
            positionId
        ));
        if (ret.length > 0) proceeds = abi.decode(ret, (uint256));
    }

    function calculatePositionValue(
        uint256 positionId
    ) external override returns (uint256 value) {
        bytes memory ret = _delegateView(tradeModule, abi.encodeWithSignature(
            "calculatePositionValue(uint256)",
            positionId
        ));
        if (ret.length > 0) value = abi.decode(ret, (uint256));
    }

    // --- Lifecycle / oracle ---

    /// @notice Create a new market with prior-based factors
    /// @dev Phase 8 Core-first Risk Gate pattern:
    ///      1. Core calls RiskModule.gateCreateMarket FIRST (α limit + prior admissibility)
    ///      2. Core delegates to MarketLifecycleModule (state machine, storage)
    ///      Per WP v2: baseFactors define the opening prior q₀,t
    ///      - Uniform prior: all factors = 1 WAD → ΔEₜ = 0
    ///      - Concentrated prior: factors vary → ΔEₜ > 0
    function createMarket(
        int256 minTick,
        int256 maxTick,
        int256 tickSpacing,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 settlementTimestamp,
        uint32 numBins,
        uint256 liquidityParameter,
        address feePolicy,
        uint256[] calldata baseFactors
    ) external override onlyOwner whenNotPaused returns (uint256 marketId) {
        // Phase 8: Risk gate FIRST - RiskModule calculates deltaEt from baseFactors
        _riskGate(abi.encodeCall(
            IRiskModule.gateCreateMarket,
            (liquidityParameter, numBins, baseFactors)
        ));

        // Then delegate to lifecycle module (state machine only, risk already validated)
        bytes memory ret = _delegate(lifecycleModule, abi.encodeWithSignature(
            "createMarket(int256,int256,int256,uint64,uint64,uint64,uint32,uint256,address,uint256[])",
            minTick,
            maxTick,
            tickSpacing,
            startTimestamp,
            endTimestamp,
            settlementTimestamp,
            numBins,
            liquidityParameter,
            feePolicy,
            baseFactors
        ));
        if (ret.length > 0) marketId = abi.decode(ret, (uint256));
    }

    function finalizePrimarySettlement(uint256 marketId) external override onlyOwner whenNotPaused {
        _delegate(lifecycleModule, abi.encodeWithSignature("finalizePrimarySettlement(uint256)", marketId));
    }

    function markSettlementFailed(uint256 marketId) external override onlyOwner whenNotPaused {
        _delegate(lifecycleModule, abi.encodeWithSignature("markSettlementFailed(uint256)", marketId));
    }

    function finalizeSecondarySettlement(
        uint256 marketId,
        int256 settlementValue
    ) external override onlyOwner whenNotPaused {
        _delegate(lifecycleModule, abi.encodeWithSignature(
            "finalizeSecondarySettlement(uint256,int256)",
            marketId,
            settlementValue
        ));
    }

    function reopenMarket(uint256 marketId) external override onlyOwner whenNotPaused {
        // Phase 8: Risk gate FIRST - get market data for validation
        ISignalsCore.Market storage market = markets[marketId];
        
        _riskGate(abi.encodeCall(
            IRiskModule.gateReopenMarket,
            (market.liquidityParameter, market.numBins, market.deltaEt)
        ));

        _delegate(lifecycleModule, abi.encodeWithSignature("reopenMarket(uint256)", marketId));
    }

    function setMarketActive(uint256 marketId, bool isActive) external override onlyOwner whenNotPaused {
        _delegate(lifecycleModule, abi.encodeWithSignature("setMarketActive(uint256,bool)", marketId, isActive));
    }

    function updateMarketTiming(
        uint256 marketId,
        uint64 startTimestamp,
        uint64 endTimestamp,
        uint64 settlementTimestamp
    ) external override onlyOwner whenNotPaused {
        _delegate(lifecycleModule, abi.encodeWithSignature(
            "updateMarketTiming(uint256,uint64,uint64,uint64)",
            marketId,
            startTimestamp,
            endTimestamp,
            settlementTimestamp
        ));
    }

    /// @notice Submit settlement sample with Redstone signed-pull oracle (WP v2 Sec 7.4)
    /// @dev Permissionless during SettlementOpen. Redstone payload is appended to calldata.
    ///      Signatures are verified on-chain by the OracleModule.
    /// @param marketId Market to submit settlement for
    function submitSettlementSample(uint256 marketId) external whenNotPaused {
        // Forward full msg.data to preserve Redstone payload appended by WrapperBuilder
        (marketId); // silence unused parameter warning
        _delegate(oracleModule, msg.data);
    }

    /// @notice Configure Redstone oracle parameters
    /// @dev WP v2 Sec 7.1: Set feed ID, decimals, and timing constraints
    function setRedstoneConfig(
        bytes32 feedId,
        uint8 feedDecimals,
        uint64 _maxSampleDistance,
        uint64 _futureTolerance
    ) external onlyOwner whenNotPaused {
        _delegate(oracleModule, abi.encodeWithSignature(
            "setRedstoneConfig(bytes32,uint8,uint64,uint64)",
            feedId,
            feedDecimals,
            _maxSampleDistance,
            _futureTolerance
        ));
    }

    /// @notice Set settlement timeline parameters (WP v2 state machine)
    /// @param _sampleWindow Δsettle: SettlementOpen duration for sample submission
    /// @param _opsWindow Δops: PendingOps duration
    /// @param _claimDelay Δclaim: Delay before claims open after finalization
    function setSettlementTimeline(
        uint64 _sampleWindow,
        uint64 _opsWindow,
        uint64 _claimDelay
    ) external onlyOwner whenNotPaused {
        settlementSubmitWindow = _sampleWindow;
        pendingOpsWindow = _opsWindow;
        claimDelaySeconds = _claimDelay;
    }

    /// @notice Get market state (derived from timestamps)
    /// @return state 0=Trading, 1=SettlementOpen, 2=PendingOps, 3=FinalizedPrimary, 4=FinalizedSecondary, 5=FailedPendingManual
    function getMarketState(uint256 marketId) external returns (uint8 state) {
        bytes memory ret = _delegateView(oracleModule, abi.encodeWithSignature(
            "getMarketState(uint256)",
            marketId
        ));
        if (ret.length > 0) state = abi.decode(ret, (uint8));
    }

    /// @notice Get settlement windows for a market
    function getSettlementWindows(uint256 marketId) external returns (
        uint64 tSet,
        uint64 settleEnd,
        uint64 opsEnd,
        uint64 claimOpen
    ) {
        bytes memory ret = _delegateView(oracleModule, abi.encodeWithSignature(
            "getSettlementWindows(uint256)",
            marketId
        ));
        if (ret.length > 0) {
            (tSet, settleEnd, opsEnd, claimOpen) = abi.decode(ret, (uint64, uint64, uint64, uint64));
        }
    }

    function getSettlementPrice(uint256 marketId)
        external
        override
        returns (int256 price, uint64 priceTimestamp)
    {
        bytes memory ret = _delegateView(oracleModule, abi.encodeWithSignature(
            "getSettlementPrice(uint256)",
            marketId
        ));
        if (ret.length > 0) (price, priceTimestamp) = abi.decode(ret, (int256, uint64));
    }

    /// @notice Trigger settlement snapshot chunks after market settlement (owner only).
    function requestSettlementChunks(uint256 marketId, uint32 maxChunksPerTx)
        external
        override
        onlyOwner
        whenNotPaused
        returns (uint32 emitted)
    {
        bytes memory ret = _delegate(lifecycleModule, abi.encodeWithSignature(
            "requestSettlementChunks(uint256,uint32)",
            marketId,
            maxChunksPerTx
        ));
        if (ret.length > 0) emitted = abi.decode(ret, (uint32));
    }

    // ============================================================
    // Vault entrypoints (delegate to LPVaultModule)
    // ============================================================

    function seedVault(uint256 seedAmount) external whenNotPaused nonReentrant {
        _delegate(vaultModule, abi.encodeWithSignature("seedVault(uint256)", seedAmount));
    }

    function requestDeposit(uint256 amount) external whenNotPaused nonReentrant returns (uint64 requestId) {
        bytes memory ret = _delegate(vaultModule, abi.encodeWithSignature("requestDeposit(uint256)", amount));
        if (ret.length > 0) requestId = abi.decode(ret, (uint64));
    }

    function requestWithdraw(uint256 shares) external whenNotPaused nonReentrant returns (uint64 requestId) {
        bytes memory ret = _delegate(vaultModule, abi.encodeWithSignature("requestWithdraw(uint256)", shares));
        if (ret.length > 0) requestId = abi.decode(ret, (uint64));
    }

    function cancelDeposit(uint64 requestId) external whenNotPaused nonReentrant {
        _delegate(vaultModule, abi.encodeWithSignature("cancelDeposit(uint64)", requestId));
    }

    function cancelWithdraw(uint64 requestId) external whenNotPaused nonReentrant {
        _delegate(vaultModule, abi.encodeWithSignature("cancelWithdraw(uint64)", requestId));
    }

    function processDailyBatch(uint64 batchId) external whenNotPaused nonReentrant {
        _delegate(vaultModule, abi.encodeWithSignature("processDailyBatch(uint64)", batchId));
    }

    function claimDeposit(uint64 requestId) external whenNotPaused nonReentrant returns (uint256 shares) {
        bytes memory ret = _delegate(vaultModule, abi.encodeWithSignature("claimDeposit(uint64)", requestId));
        if (ret.length > 0) shares = abi.decode(ret, (uint256));
    }

    function claimWithdraw(uint64 requestId) external whenNotPaused nonReentrant returns (uint256 assets) {
        bytes memory ret = _delegate(vaultModule, abi.encodeWithSignature("claimWithdraw(uint64)", requestId));
        if (ret.length > 0) assets = abi.decode(ret, (uint256));
    }

    // ============================================================
    // Vault View Functions (direct storage read for ERC-4626)
    // ============================================================

    /// @notice Get current vault NAV
    function getVaultNav() external view returns (uint256) {
        return lpVault.nav;
    }

    /// @notice Get current vault total shares
    function getVaultShares() external view returns (uint256) {
        return lpVault.shares;
    }

    /// @notice Get current vault share price (P = N/S)
    function getVaultPrice() external view returns (uint256) {
        return lpVault.price;
    }

    /// @notice Check if vault is seeded
    function isVaultSeeded() external view returns (bool) {
        return lpVault.isSeeded;
    }

    /// @notice Get vault peak price
    function getVaultPricePeak() external view returns (uint256) {
        return lpVault.pricePeak;
    }

    /// @notice Get current vault drawdown
    /// @return drawdown Drawdown in WAD (0 = no drawdown, 1e18 = 100%)
    function getVaultDrawdown() external view returns (uint256 drawdown) {
        if (lpVault.pricePeak == 0 || lpVault.price >= lpVault.pricePeak) {
            return 0;
        }
        return WAD - (lpVault.price * WAD) / lpVault.pricePeak;
    }

    /// @notice Get current risk configuration
    function getRiskConfig() external view returns (
        uint256 lambda,
        uint256 kDrawdown,
        bool enforceAlpha
    ) {
        return (riskConfig.lambda, riskConfig.kDrawdown, riskConfig.enforceAlpha);
    }

    /// @notice Get fee waterfall configuration
    function getFeeWaterfallConfig() external view returns (
        uint256 rhoBS,
        int256 pdd,
        uint256 phiLP,
        uint256 phiBS,
        uint256 phiTR
    ) {
        return (
            feeWaterfallConfig.rhoBS,
            feeWaterfallConfig.pdd,
            feeWaterfallConfig.phiLP,
            feeWaterfallConfig.phiBS,
            feeWaterfallConfig.phiTR
        );
    }

    /// @notice Get capital stack state
    function getCapitalStack() external view returns (
        uint256 backstopNav,
        uint256 treasuryNav
    ) {
        return (capitalStack.backstopNav, capitalStack.treasuryNav);
    }

    /// @notice Get current batch ID
    function getCurrentBatchId() external view returns (uint64) {
        return currentBatchId;
    }

    /// @notice Get withdrawal lag in batches
    function getWithdrawalLagBatches() external view returns (uint64) {
        return withdrawalLagBatches;
    }

    function getDailyPnl(uint64 batchId)
        external
        returns (
            int256 lt,
            uint256 ftot,
            uint256 ft,
            uint256 gt,
            uint256 npre,
            uint256 pe,
            bool processed
        )
    {
        bytes memory ret = _delegateView(vaultModule, abi.encodeWithSignature("getDailyPnl(uint64)", batchId));
        if (ret.length > 0) (lt, ftot, ft, gt, npre, pe, processed) = abi.decode(
            ret,
            (int256, uint256, uint256, uint256, uint256, uint256, bool)
        );
    }

    // --- Internal: delegate helpers ---

    /// @dev Delegate to a module preserving context, bubble up revert
    function _delegate(address module, bytes memory callData) internal returns (bytes memory) {
        if (module == address(0)) revert ModuleNotSet();
        (bool success, bytes memory ret) = module.delegatecall(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    /// @dev Delegate to a module for view paths via staticcall; bubble up reverts.
    function _delegateView(address module, bytes memory callData) internal returns (bytes memory) {
        if (module == address(0)) revert ModuleNotSet();
        (bool success, bytes memory ret) = module.delegatecall(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    // ============================================================
    // Phase 8: Risk Gate Pattern
    // ============================================================

    /// @dev Execute risk gate via delegatecall, bubble up revert
    /// @param gateCalldata Encoded call to RiskModule gate function
    function _riskGate(bytes memory gateCalldata) internal {
        if (riskModule == address(0)) revert ModuleNotSet();
        (bool success, bytes memory ret) = riskModule.delegatecall(gateCalldata);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
