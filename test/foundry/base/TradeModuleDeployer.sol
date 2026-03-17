// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SignalsBaseTest.sol";

import "../../../contracts/testonly/SignalsUSDToken.sol";
import "../../../contracts/testonly/MockFeePolicy.sol";
import "../../../contracts/testonly/TradeModuleProxy.sol";
import "../../../contracts/testonly/TestERC1967Proxy.sol";
import "../../../contracts/position/SignalsPosition.sol";
import "../../../contracts/modules/TradeModule.sol";
import "../../../contracts/interfaces/ISignalsCore.sol";

/// @title TradeModuleDeployer
/// @notice Deploys a TradeModuleProxy-based system mirroring test/helpers/deploy.ts.
/// @dev TradeModuleProxy has NO access control — setMarket, seedTree, setAddresses are public.
abstract contract TradeModuleDeployer is SignalsBaseTest {
    struct TradeModuleSystem {
        address owner;
        address[] users;
        SignalsUSDToken payment;
        SignalsPosition position;
        MockFeePolicy feePolicy;
        TradeModule tradeModule;
        TradeModuleProxy core;
    }

    struct MarketConfig {
        uint32 numBins;
        int256 tickSpacing;
        int256 minTick;
        int256 maxTick;
        uint256 endOffset;
        uint256 liquidityParameter;
    }

    struct DeployOptions {
        MarketConfig[] markets;
        uint256 userCount;
        uint256 fundAmount;
        uint64 submitWindow;
        uint64 settlementWindow;
    }

    // ============================================================
    // Core deployment
    // ============================================================

    function deployTradeModuleSystem(DeployOptions memory opts) internal returns (TradeModuleSystem memory sys) {
        // Create owner and users
        sys.owner = makeAddr("owner");
        vm.deal(sys.owner, 1 ether);

        sys.users = new address[](opts.userCount);
        for (uint256 i = 0; i < opts.userCount; i++) {
            sys.users[i] = makeAddr(string.concat("user", vm.toString(i + 1)));
            vm.deal(sys.users[i], 1 ether);
        }

        // Deploy tokens and fee policy
        sys.payment = new SignalsUSDToken();
        sys.feePolicy = new MockFeePolicy(0);

        // Deploy TradeModule (auto-links LazyMulSegmentTree)
        sys.tradeModule = new TradeModule();

        // Deploy TradeModuleProxy (also uses LazyMulSegmentTree)
        sys.core = new TradeModuleProxy(address(sys.tradeModule));

        // Deploy SignalsPosition with UUPS proxy
        SignalsPosition positionImpl = new SignalsPosition();
        bytes memory positionInit = abi.encodeCall(SignalsPosition.initialize, (address(sys.core), sys.owner));
        TestERC1967Proxy positionProxy = new TestERC1967Proxy(address(positionImpl), positionInit);
        sys.position = SignalsPosition(address(positionProxy));

        // Configure addresses (no access control on TradeModuleProxy)
        sys.core.setAddresses(address(sys.payment), address(sys.position), opts.submitWindow, opts.settlementWindow);

        // Set up markets
        uint256 now_ = block.timestamp;
        for (uint256 i = 0; i < opts.markets.length; i++) {
            uint256 marketId = i + 1;
            MarketConfig memory cfg = opts.markets[i];
            uint256 endOffset = cfg.endOffset == 0 ? 10_000 : cfg.endOffset;
            uint256 liqParam = cfg.liquidityParameter == 0 ? WAD : cfg.liquidityParameter;

            ISignalsCore.Market memory market = ISignalsCore.Market({
                isSeeded: true,
                settled: false,
                snapshotChunksDone: false,
                failed: false,
                numBins: cfg.numBins,
                openPositionCount: 0,
                snapshotChunkCursor: 0,
                seedCursor: cfg.numBins,
                startTimestamp: uint64(now_ - 10),
                endTimestamp: uint64(now_ + endOffset),
                settlementTimestamp: uint64(now_ + endOffset + 100),
                settlementFinalizedAt: 0,
                minTick: cfg.minTick,
                maxTick: cfg.maxTick,
                tickSpacing: cfg.tickSpacing,
                settlementTick: 0,
                settlementValue: 0,
                liquidityParameter: liqParam,
                feePolicy: address(sys.feePolicy),
                seedData: address(0),
                initialRootSum: uint256(cfg.numBins) * WAD,
                accumulatedFees: 0,
                minFactor: WAD,
                deltaEt: 0
            });

            sys.core.setMarket(marketId, market);
            sys.core.seedTree(marketId, uniformFactors(cfg.numBins));
        }

        // Fund users
        uint256 fundAmount = opts.fundAmount == 0 ? 100_000e6 : opts.fundAmount;
        for (uint256 i = 0; i < sys.users.length; i++) {
            sys.payment.transfer(sys.users[i], fundAmount);
            vm.prank(sys.users[i]);
            sys.payment.approve(address(sys.core), type(uint256).max);
        }
    }

    // ============================================================
    // Convenience deployers
    // ============================================================

    function deployMinimalTradeSystem() internal returns (TradeModuleSystem memory) {
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 4,
            endOffset: 10_000,
            liquidityParameter: WAD
        });

        return
            deployTradeModuleSystem(
                DeployOptions({
                    markets: markets,
                    userCount: 1,
                    fundAmount: 100_000e6,
                    submitWindow: 300,
                    settlementWindow: 60
                })
            );
    }

    function deployMultiMarketSystem() internal returns (TradeModuleSystem memory) {
        MarketConfig[] memory markets = new MarketConfig[](2);
        markets[0] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: 0,
            maxTick: 4,
            endOffset: 10_000,
            liquidityParameter: WAD
        });
        markets[1] = MarketConfig({
            numBins: 4,
            tickSpacing: 1,
            minTick: -2,
            maxTick: 2,
            endOffset: 10_000,
            liquidityParameter: WAD
        });

        return
            deployTradeModuleSystem(
                DeployOptions({
                    markets: markets,
                    userCount: 5,
                    fundAmount: 100_000e6,
                    submitWindow: 300,
                    settlementWindow: 60
                })
            );
    }

    function deployLargeBinSystem(uint32 numBins) internal returns (TradeModuleSystem memory) {
        MarketConfig[] memory markets = new MarketConfig[](1);
        markets[0] = MarketConfig({
            numBins: numBins,
            tickSpacing: 1,
            minTick: 0,
            maxTick: int256(uint256(numBins)),
            endOffset: 10_000,
            liquidityParameter: WAD
        });

        return
            deployTradeModuleSystem(
                DeployOptions({
                    markets: markets,
                    userCount: 5,
                    fundAmount: 1_000_000e6,
                    submitWindow: 300,
                    settlementWindow: 60
                })
            );
    }
}
