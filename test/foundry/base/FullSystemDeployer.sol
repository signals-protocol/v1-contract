// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SignalsBaseTest.sol";

import "../../../contracts/testonly/SignalsUSDToken.sol";
import "../../../contracts/testonly/MockFeePolicy.sol";
import "../../../contracts/testonly/SignalsCoreHarness.sol";
import "../../../contracts/testonly/OracleModuleHarness.sol";
import "../../../contracts/testonly/TestERC1967Proxy.sol";
import "../../../contracts/position/SignalsPosition.sol";
import "../../../contracts/tokens/SignalsLPShare.sol";
import "../../../contracts/modules/TradeModule.sol";
import "../../../contracts/modules/MarketLifecycleModule.sol";
import "../../../contracts/modules/RiskModule.sol";
import "../../../contracts/modules/LPVaultModule.sol";
import "../../../contracts/core/SignalsCore.sol";

/// @title FullSystemDeployer
/// @notice Deploys the full SignalsCore protocol mirroring test/helpers/fullSystem.ts.
/// @dev Uses SignalsCoreHarness (extends SignalsCore) so harness functions are available.
///      SignalsCoreHarness has onlyOwner on harnessSetMarket, harnessSeedTree, etc.
abstract contract FullSystemDeployer is SignalsBaseTest {
    struct FullSystem {
        address owner;
        address[] users;
        SignalsUSDToken payment;
        MockFeePolicy feePolicy;
        SignalsCoreHarness core;
        SignalsPosition position;
        TradeModule tradeModule;
        MarketLifecycleModule lifecycleModule;
        OracleModuleHarness oracleModule;
        RiskModule riskModule;
        LPVaultModule vaultModule;
        SignalsLPShare lpShare;
    }

    function deployFullSystem() internal returns (FullSystem memory) {
        return _deployFullSystem(5, 5);
    }

    function deployFullSystem(uint64 submitWindow, uint64 opsWindow) internal returns (FullSystem memory) {
        return _deployFullSystem(submitWindow, opsWindow);
    }

    function _deployFullSystem(uint64 submitWindow, uint64 opsWindow) private returns (FullSystem memory sys) {
        uint64 claimDelay = submitWindow + opsWindow;

        // Create owner and users
        sys.owner = makeAddr("owner");
        vm.deal(sys.owner, 1 ether);
        sys.users = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            sys.users[i] = makeAddr(string.concat("user", vm.toString(i + 1)));
            vm.deal(sys.users[i], 1 ether);
        }

        // 1. Deploy tokens
        sys.payment = new SignalsUSDToken();
        sys.feePolicy = new MockFeePolicy(0);

        // 2. Deploy modules (TradeModule and MarketLifecycleModule auto-link LazyMulSegmentTree)
        sys.tradeModule = new TradeModule();
        sys.lifecycleModule = new MarketLifecycleModule();
        sys.oracleModule = new OracleModuleHarness();
        sys.riskModule = new RiskModule();
        sys.vaultModule = new LPVaultModule();

        // 3. Deploy implementations
        // SignalsCoreHarness extends SignalsCore — auto-links LazyMulSegmentTree
        SignalsPosition positionImpl = new SignalsPosition();
        SignalsLPShare lpShareImpl = new SignalsLPShare();
        SignalsCoreHarness coreImpl = new SignalsCoreHarness();

        // 4. Deploy proxies with empty init data (matching fullSystem.ts:106-108)
        TestERC1967Proxy positionProxy = new TestERC1967Proxy(address(positionImpl), "");
        TestERC1967Proxy lpShareProxy = new TestERC1967Proxy(address(lpShareImpl), "");
        TestERC1967Proxy coreProxy = new TestERC1967Proxy(address(coreImpl), "");

        // 5. Cast proxies
        sys.position = SignalsPosition(address(positionProxy));
        sys.lpShare = SignalsLPShare(address(lpShareProxy));
        sys.core = SignalsCoreHarness(address(coreProxy));

        // 6. Initialize core — initializer modifier (one-time call, no prank needed)
        SignalsCore.InitParams memory params = SignalsCore.InitParams({
            paymentToken: address(sys.payment),
            positionContract: address(sys.position),
            lpShareToken: address(sys.lpShare),
            tradeModule: address(sys.tradeModule),
            lifecycleModule: address(sys.lifecycleModule),
            riskModule: address(sys.riskModule),
            vaultModule: address(sys.vaultModule),
            oracleModule: address(sys.oracleModule),
            ownerSafe: sys.owner,
            settlementSubmitWindow: submitWindow,
            pendingOpsWindow: opsWindow,
            claimDelaySeconds: claimDelay,
            redstoneFeedId: bytes32("BTC"),
            redstoneFeedDecimals: 8,
            maxSampleDistance: 600,
            futureTolerance: 60,
            lambda: WAD / 10,
            kDrawdown: WAD,
            enforceAlpha: true,
            rhoBS: 0,
            phiLP: WAD,
            phiBS: 0,
            phiTR: 0,
            withdrawalLagBatches: 1,
            operatorAllowlist: _singletonArray(sys.owner)
        });
        sys.core.initialize(params);

        // 7. Initialize position and lpShare (initializer modifier, no prank)
        sys.position.initialize(address(sys.core), sys.owner);
        sys.lpShare.initialize(address(sys.core), address(sys.payment), "Signals LP", "SIGLP", sys.owner);
    }

    function _singletonArray(address addr) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = addr;
    }
}
