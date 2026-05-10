// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../base/FullSystemDeployer.sol";
import "../../base/SeedHelper.sol";
import {SignalsErrors as SE} from "../../../../contracts/errors/SignalsErrors.sol";

/// @title Risk Gate E2E Test
/// @notice 1 test: rejects markets exceeding alpha limit, allows compliant markets
contract RiskGateTest is FullSystemDeployer {
    FullSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(5, 5);
    }

    function test_rejects_markets_exceeding_alpha_limit() public {
        address coreAddress = address(sys.core);

        // Seed vault
        uint256 seedAmount = 1_000_000;
        sys.payment.mint(sys.owner, seedAmount);
        vm.startPrank(sys.owner);
        sys.payment.approve(coreAddress, seedAmount);
        sys.core.seedVault(seedAmount);
        vm.stopPrank();

        // Enable alpha enforcement
        vm.prank(sys.owner);
        sys.core.setRiskConfig(0.3e18, WAD, true);

        uint64 start = uint64(block.timestamp - 5);
        uint64 end = uint64(block.timestamp + 5);
        uint64 settlement = uint64(block.timestamp + 10);

        uint256[] memory factors = uniformFactors(4);
        SeedData seedData = SeedHelper.deploySeedData(factors);

        // Should revert: alpha = 10 WAD exceeds limit
        vm.prank(sys.owner);
        vm.expectPartialRevert(SE.AlphaExceedsLimit.selector);
        sys.core.createMarket(0, 4, 1, start, end, settlement, 4, 10e18, address(sys.feePolicy), address(seedData));

        // Should succeed: alpha = 0.1 WAD is within limit
        SeedData seedData2 = SeedHelper.deploySeedData(factors);
        vm.prank(sys.owner);
        uint256 marketId = sys.core
            .createMarket(0, 4, 1, start, end, settlement + 100, 4, 0.1e18, address(sys.feePolicy), address(seedData2));

        vm.prank(sys.owner);
        sys.core.seedNextChunks(marketId, 4);

        ISignalsCore.Market memory market = sys.core.harnessGetMarket(marketId);
        assertEq(market.numBins, 4);
    }
}
