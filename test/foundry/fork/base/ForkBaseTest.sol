// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../../../contracts/core/SignalsCore.sol";
import "../../../../contracts/interfaces/ISignalsCore.sol";
import "../../../../contracts/modules/MarketLifecycleModule.sol";
import "../../../../contracts/modules/OracleModule.sol";
import "../../../../contracts/position/SignalsPosition.sol";
import "../../../../contracts/tokens/SignalsLPShare.sol";

/// @title ForkBaseTest
/// @notice Base contract for fork tests that operate on production chain state.
///         Loads addresses from environment JSON and creates a forked network.
abstract contract ForkBaseTest is Test {
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant BATCH_AGGREGATIONS_SLOT = 28;
    uint256 internal constant BATCH_AGGREGATION_PROCESSED_SLOT_OFFSET = 3;
    uint256 internal constant CURRENT_BATCH_ID_SLOT = 30;
    uint256 internal constant CURRENT_BATCH_ID_OFFSET_BITS = 128;

    string internal envName;
    string internal envJsonPath;

    SignalsCore internal core;
    SignalsPosition internal position;
    SignalsLPShare internal lpShare;

    address internal ownerSafe;
    address internal paymentToken;

    /// @dev Pin prod fork to a known-good baseline block so the suite stays deterministic
    /// as live state evolves. Block 6029250 ≈ 2026-04-14 09:31 UTC matches the last
    /// green Fork Tests Baseline run on `main`. Override via `FORK_BLOCK` to bump the pin.
    /// Dev fork remains on latest because the dev chain has no baseline mapping.
    uint256 internal constant PROD_BASELINE_FORK_BLOCK = 6029250;

    function setUp() public virtual {
        envName = vm.envOr("FORK_ENV", string("dev"));
        envJsonPath = string.concat("scripts/environments/", envName, ".json");

        if (_isDevEnv()) {
            vm.createSelectFork(envName);
        } else {
            uint256 forkBlock = vm.envOr("FORK_BLOCK", PROD_BASELINE_FORK_BLOCK);
            vm.createSelectFork(envName, forkBlock);
        }

        uint256 expectedChain = _isDevEnv() ? 5115 : 4114;
        assertEq(block.chainid, expectedChain, "chain ID mismatch");

        core = SignalsCore(_contractAddr("SignalsCoreProxy"));
        position = SignalsPosition(_contractAddr("SignalsPositionProxy"));
        lpShare = SignalsLPShare(_lpShareAddr());
        ownerSafe = _requireConfigAddr("owners.core");
        paymentToken = _contractAddr("PaymentToken");

        assertTrue(address(core).code.length > 0, "core proxy has no code");

        if (!vm.envOr("FORK_SKIP_V2_UPGRADE", false)) {
            _forkAndUpgradeToV2();
        }

        if (_isDevEnv()) {
            _alignCurrentBatchToDevForkState();
        }
    }

    function _forkAndUpgradeToV2() internal {
        SignalsCore newImpl = new SignalsCore();
        MarketLifecycleModule newLifecycle = new MarketLifecycleModule();
        OracleModule newOracle = new OracleModule();

        address tradeModule = core.tradeModule();
        address riskModule = core.riskModule();
        address vaultModule = core.vaultModule();

        vm.startPrank(ownerSafe);
        core.upgradeToAndCall(address(newImpl), abi.encodeCall(SignalsCore.reinitializeV2, ()));
        core.setModules(tradeModule, address(newLifecycle), riskModule, vaultModule, address(newOracle));
        vm.stopPrank();
    }

    function _alignCurrentBatchToDevForkState() internal {
        uint64 alignedBatchId = core.getCurrentBatchId();

        for (uint256 i = 0; i < 365; i++) {
            uint64 nextBatchId = alignedBatchId + 1;
            if (!_dailyPnlProcessed(nextBatchId) && !_batchAggregationProcessed(nextBatchId)) break;
            alignedBatchId++;
        }

        if (alignedBatchId != core.getCurrentBatchId()) {
            _writeCurrentBatchId(alignedBatchId);
        }
    }

    function _dailyPnlProcessed(uint64 batchId) internal returns (bool processed) {
        (,,,,,, processed) = core.getDailyPnl(batchId);
    }

    function _batchAggregationProcessed(uint64 batchId) internal view returns (bool) {
        bytes32 baseSlot = keccak256(abi.encode(batchId, uint256(BATCH_AGGREGATIONS_SLOT)));
        bytes32 processedSlot = bytes32(uint256(baseSlot) + BATCH_AGGREGATION_PROCESSED_SLOT_OFFSET);
        return uint256(vm.load(address(core), processedSlot)) != 0;
    }

    function _writeCurrentBatchId(uint64 batchId) internal {
        bytes32 slot = bytes32(CURRENT_BATCH_ID_SLOT);
        uint256 word = uint256(vm.load(address(core), slot));
        uint256 mask = uint256(type(uint64).max) << CURRENT_BATCH_ID_OFFSET_BITS;
        uint256 updated = (word & ~mask) | (uint256(batchId) << CURRENT_BATCH_ID_OFFSET_BITS);
        vm.store(address(core), slot, bytes32(updated));
    }

    // --- JSON helpers (adapted from BaseScript.s.sol) ---

    function _loadEnvJson() internal view returns (string memory) {
        return vm.readFile(envJsonPath);
    }

    function _contractAddr(string memory key) internal view returns (address) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".contracts.", key);
        return vm.parseJsonAddress(json, path);
    }

    function _tryContractAddr(string memory key) internal view returns (address) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".contracts.", key);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return vm.parseJsonAddress(json, path);
    }

    function _requireConfigAddr(string memory key) internal view returns (address) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".config.", key);
        require(vm.keyExistsJson(json, path), string.concat("missing config key: ", key));
        return vm.parseJsonAddress(json, path);
    }

    function _tryConfigUint(string memory key) internal view returns (uint256) {
        string memory json = _loadEnvJson();
        string memory path = string.concat(".config.", key);
        if (!vm.keyExistsJson(json, path)) return 0;
        return vm.parseJsonUint(json, path);
    }

    function _implAddress(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPL_SLOT))));
    }

    function _isDevEnv() internal view returns (bool) {
        return keccak256(bytes(envName)) == keccak256("dev");
    }

    function _lpShareAddr() internal view returns (address) {
        address addr = _tryContractAddr("SignalsLPShareProxy");
        if (addr == address(0)) addr = _contractAddr("SignalsLPShare");
        return addr;
    }

    // --- Market snapshot helpers ---

    struct MarketSnapshot {
        bool isSeeded;
        bool settled;
        uint32 numBins;
        uint64 startTs;
        uint64 endTs;
        uint256 liquidityParameter;
        uint256 initialRootSum;
    }

    function _readMarket(uint256 marketId) internal view returns (MarketSnapshot memory snap) {
        ISignalsCore.Market memory market = core.getMarket(marketId);
        snap.isSeeded = market.isSeeded;
        snap.settled = market.settled;
        snap.numBins = market.numBins;
        snap.startTs = market.startTimestamp;
        snap.endTs = market.endTimestamp;
        snap.liquidityParameter = market.liquidityParameter;
        snap.initialRootSum = market.initialRootSum;
    }
}
