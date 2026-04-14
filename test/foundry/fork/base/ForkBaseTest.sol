// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../../../contracts/core/SignalsCore.sol";
import "../../../../contracts/interfaces/ISignalsCore.sol";
import "../../../../contracts/position/SignalsPosition.sol";
import "../../../../contracts/tokens/SignalsLPShare.sol";

/// @title ForkBaseTest
/// @notice Base contract for fork tests that operate on production chain state.
///         Loads addresses from environment JSON and creates a forked network.
abstract contract ForkBaseTest is Test {
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

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
