// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../../../contracts/core/SignalsCore.sol";
import "../../../../contracts/position/SignalsPosition.sol";
import "../../../../contracts/tokens/SignalsLPShare.sol";

/// @title ForkBaseTest
/// @notice Base contract for fork tests that operate on production chain state.
///         Loads addresses from environment JSON and creates a forked network.
abstract contract ForkBaseTest is Test {
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Hardcoded selector for markets(uint256) — deployed proxy still exposes
    ///      the auto getter. Switch to core.getMarket() after on-chain upgrade.
    bytes4 private constant MARKETS_SELECTOR = bytes4(keccak256("markets(uint256)"));

    string internal envName;
    string internal envJsonPath;

    SignalsCore internal core;
    SignalsPosition internal position;
    SignalsLPShare internal lpShare;

    address internal ownerSafe;
    address internal paymentToken;

    function setUp() public virtual {
        envName = vm.envOr("FORK_ENV", string("dev"));
        envJsonPath = string.concat("scripts/environments/", envName, ".json");

        vm.createSelectFork(envName);

        uint256 expectedChain = _isDevEnv() ? 5115 : 4114;
        assertEq(block.chainid, expectedChain, "chain ID mismatch");

        core = SignalsCore(_contractAddr("SignalsCoreProxy"));
        position = SignalsPosition(_contractAddr("SignalsPositionProxy"));
        lpShare = SignalsLPShare(_lpShareAddr());
        ownerSafe = _requireConfigAddr("owners.core");
        paymentToken = _contractAddr("PaymentToken");

        assertTrue(address(core).code.length > 0, "core proxy has no code");
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

    // --- Market snapshot helpers (avoids stack-too-deep with 24-field tuple) ---

    struct MarketSnapshot {
        bool isSeeded;
        bool settled;
        uint32 numBins;
        uint64 startTs;
        uint64 endTs;
        uint256 liquidityParameter;
        uint256 initialRootSum;
    }

    /// @dev Reads market data via staticcall and decodes only the fields we need,
    ///      avoiding stack-too-deep from destructuring the 24-field Market tuple.
    function _readMarket(uint256 marketId) internal view returns (MarketSnapshot memory snap) {
        (bool success, bytes memory data) = address(core).staticcall(
            abi.encodeWithSelector(MARKETS_SELECTOR, marketId)
        );
        require(success, "markets() staticcall failed");

        // Market struct ABI word indices (each 32 bytes):
        // 0:isSeeded, 1:settled, 2:snapshotChunksDone, 3:failed,
        // 4:numBins, 5:openPositionCount, 6:snapshotChunkCursor, 7:seedCursor,
        // 8:startTimestamp, 9:endTimestamp, 10:settlementTimestamp, 11:settlementFinalizedAt,
        // 12:minTick, 13:maxTick, 14:tickSpacing, 15:settlementTick, 16:settlementValue,
        // 17:liquidityParameter, 18:feePolicy, 19:seedData, 20:initialRootSum,
        // 21:accumulatedFees, 22:minFactor, 23:deltaEt
        snap.isSeeded = _decodeWordBool(data, 0);
        snap.settled = _decodeWordBool(data, 1);
        snap.numBins = uint32(_decodeWord(data, 4));
        snap.startTs = uint64(_decodeWord(data, 8));
        snap.endTs = uint64(_decodeWord(data, 9));
        snap.liquidityParameter = _decodeWord(data, 17);
        snap.initialRootSum = _decodeWord(data, 20);
    }

    function _decodeWord(bytes memory data, uint256 wordIndex) internal pure returns (uint256 value) {
        uint256 offset = wordIndex * 32;
        assembly {
            value := mload(add(add(data, 32), offset))
        }
    }

    function _decodeWordBool(bytes memory data, uint256 wordIndex) internal pure returns (bool) {
        return _decodeWord(data, wordIndex) != 0;
    }
}
