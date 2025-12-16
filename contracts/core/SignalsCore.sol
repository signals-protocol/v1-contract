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
        settlementFinalizeDeadline = _settlementFinalizeDeadline;
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
    }

    // ============================================================
    // Vault configuration (Phase 6)
    // ============================================================

    function setMinSeedAmount(uint256 amount) external onlyOwner whenNotPaused {
        if (amount == 0) revert CE.ZeroLimit();
        minSeedAmount = amount;
    }

    function setWithdrawalLagBatches(uint64 lag) external onlyOwner whenNotPaused {
        withdrawalLagBatches = lag;
    }

    function setFeeWaterfallConfig(
        int256 pdd,
        uint256 rhoBS,
        uint256 phiLP,
        uint256 phiBS,
        uint256 phiTR
    ) external onlyOwner whenNotPaused {
        if (phiLP + phiBS + phiTR != WAD) revert InvalidFeeSplitSum(phiLP, phiBS, phiTR);
        feeWaterfallConfig.pdd = pdd;
        feeWaterfallConfig.rhoBS = rhoBS;
        feeWaterfallConfig.phiLP = phiLP;
        feeWaterfallConfig.phiBS = phiBS;
        feeWaterfallConfig.phiTR = phiTR;
    }

    function setCapitalStack(uint256 backstopNav, uint256 treasuryNav) external onlyOwner whenNotPaused {
        capitalStack.backstopNav = backstopNav;
        capitalStack.treasuryNav = treasuryNav;
    }

    /// @notice Set tail budget (ΔEₜ) for grant calculations
    /// @dev Per whitepaper v2: ΔEₜ := E_ent(q₀,t) - α_t ln n
    ///      V1 (uniform prior): ΔEₜ = 0 (default)
    ///      For testing grant mechanics, can be set to backstopNav or other values
    /// @param deltaEt Tail budget in WAD (0 = uniform prior, no tail risk)
    function setDeltaEt(uint256 deltaEt) external onlyOwner whenNotPaused {
        feeWaterfallConfig.deltaEt = deltaEt;
    }

    /// @notice Configure risk parameters for α Safety Bounds (Phase 7)
    /// @dev Per whitepaper v2: pdd := -λ (drawdown floor equals negative lambda)
    ///      This function enforces the relationship by auto-updating pdd when lambda is set.
    /// @param lambda λ: Safety parameter (WAD), e.g., 0.3e18 = 30% max drawdown
    /// @param kDrawdown k: Drawdown sensitivity factor (WAD), typically 1.0e18
    /// @param enforceAlpha Whether to enforce α bounds at market configuration time (create/reopen)
    function setRiskConfig(
        uint256 lambda,
        uint256 kDrawdown,
        bool enforceAlpha
    ) external onlyOwner whenNotPaused {
        riskConfig.lambda = lambda;
        riskConfig.kDrawdown = kDrawdown;
        riskConfig.enforceAlpha = enforceAlpha;
        
        // Whitepaper v2 invariant: pdd := -λ
        // Auto-update drawdown floor to maintain Safety guarantee
        feeWaterfallConfig.pdd = -int256(lambda);
    }

    // --- External stubs: delegate to modules ---

    function openPosition(
        uint256 marketId,
        int256 lowerTick,
        int256 upperTick,
        uint128 quantity,
        uint256 maxCost
    ) external override whenNotPaused nonReentrant returns (uint256 positionId) {
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

    /// @notice Create a new market with prior-based factors (Phase 7)
    /// @dev Per WP v2: baseFactors define the opening prior q₀,t
    ///      - Uniform prior: all factors = 1 WAD → ΔEₜ = 0
    ///      - Concentrated prior: factors vary → ΔEₜ > 0
    ///      Prior admissibility is checked: ΔEₜ ≤ B_eff
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

    function settleMarket(uint256 marketId) external override onlyOwner whenNotPaused {
        _delegate(lifecycleModule, abi.encodeWithSignature("settleMarket(uint256)", marketId));
    }

    function markFailed(uint256 marketId) external override onlyOwner whenNotPaused {
        _delegate(lifecycleModule, abi.encodeWithSignature("markFailed(uint256)", marketId));
    }

    function manualSettleFailedMarket(
        uint256 marketId,
        int256 settlementValue
    ) external override onlyOwner whenNotPaused {
        _delegate(lifecycleModule, abi.encodeWithSignature(
            "manualSettleFailedMarket(uint256,int256)",
            marketId,
            settlementValue
        ));
    }

    function reopenMarket(uint256 marketId) external override onlyOwner whenNotPaused {
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

    function submitSettlementPrice(
        uint256 marketId,
        int256 settlementValue,
        uint64 priceTimestamp,
        bytes calldata signature
    ) external override whenNotPaused {
        _delegate(oracleModule, abi.encodeWithSignature(
            "submitSettlementPrice(uint256,int256,uint64,bytes)",
            marketId,
            settlementValue,
            priceTimestamp,
            signature
        ));
    }

    function setOracleConfig(address signer) external override onlyOwner whenNotPaused {
        _delegate(oracleModule, abi.encodeWithSignature("setOracleConfig(address)", signer));
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

    // Views (delegate to LPVaultModule)

    function getVaultNav() external returns (uint256 nav) {
        bytes memory ret = _delegateView(vaultModule, abi.encodeWithSignature("getVaultNav()"));
        if (ret.length > 0) nav = abi.decode(ret, (uint256));
    }

    function getVaultShares() external returns (uint256 shares) {
        bytes memory ret = _delegateView(vaultModule, abi.encodeWithSignature("getVaultShares()"));
        if (ret.length > 0) shares = abi.decode(ret, (uint256));
    }

    function getVaultPrice() external returns (uint256 price) {
        bytes memory ret = _delegateView(vaultModule, abi.encodeWithSignature("getVaultPrice()"));
        if (ret.length > 0) price = abi.decode(ret, (uint256));
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

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
