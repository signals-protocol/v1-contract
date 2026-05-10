// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../base/FullSystemDeployer.sol";
import {SignalsErrors as SE} from "../../../contracts/errors/SignalsErrors.sol";
import {SeedData} from "../../../contracts/utils/SeedData.sol";

/// @title Market Security Tests
/// @notice Foundry port of test/security/market.security.spec.ts (10 tests)
/// @dev numBins hard cap enforcement, market parameter validation, createMarketUniform cap
contract MarketSecurityTest is FullSystemDeployer {
    FullSystem internal sys;

    function setUp() public override {
        super.setUp();
        sys = deployFullSystem(3600, 3600);

        sys.payment.mint(sys.owner, 1_000_000e6);

        vm.prank(sys.owner);
        sys.payment.approve(address(sys.core), type(uint256).max);

        vm.prank(sys.owner);
        sys.core.seedVault(100_000e6);
    }

    function _deploySeedData(uint32 numBins) internal returns (address) {
        uint256[] memory factors = uniformFactors(numBins);
        bytes memory encoded;
        for (uint256 i = 0; i < factors.length; i++) {
            encoded = abi.encodePacked(encoded, factors[i]);
        }
        SeedData sd = new SeedData(encoded);
        return address(sd);
    }

    function _deploySeedDataRaw(uint256 numBins) internal returns (address) {
        // Deploy seed data with specified numBins (may not match actual market numBins)
        uint256[] memory factors = new uint256[](numBins);
        for (uint256 i = 0; i < numBins; i++) {
            factors[i] = WAD;
        }
        bytes memory encoded;
        for (uint256 i = 0; i < factors.length; i++) {
            encoded = abi.encodePacked(encoded, factors[i]);
        }
        SeedData sd = new SeedData(encoded);
        return address(sd);
    }

    // ============================================================
    // numBins Hard Cap
    // ============================================================

    function test_rejects_market_where_maxTick_plus_tickSpacing_would_overflow_int256() public {
        uint64 now_ = uint64(block.timestamp);
        int256 maxInt256 = type(int256).max;
        int256 maxTick = maxInt256;
        int256 minTick = maxTick - 4;
        address seed = _deploySeedData(4);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidMarketParameters.selector, minTick, maxTick, int256(1)));
        sys.core
            .createMarket(
                minTick, maxTick, 1, now_ - 100, now_ + 10000, now_ + 10100, 4, WAD, address(sys.feePolicy), seed
            );
    }

    function test_rejects_market_where_tick_span_exceeds_uint32_bins() public {
        uint64 now_ = uint64(block.timestamp);
        int256 minTick = 0;
        int256 maxTick = int256(int256(1) << 32) + 4;
        address seed = _deploySeedData(4);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidMarketParameters.selector, minTick, maxTick, int256(1)));
        sys.core
            .createMarket(
                minTick, maxTick, 1, now_ - 100, now_ + 10000, now_ + 10100, 4, WAD, address(sys.feePolicy), seed
            );
    }

    function test_rejects_market_creation_with_numBins_zero() public {
        uint64 now_ = uint64(block.timestamp);
        // Empty seed data for 0 bins
        SeedData sd = new SeedData("");
        address seed = address(sd);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidNumBins.selector, uint256(0)));
        sys.core.createMarket(0, 10, 1, now_ - 100, now_ + 10000, now_ + 10100, 0, WAD, address(sys.feePolicy), seed);
    }

    function test_rejects_market_creation_with_numBins_gt_256() public {
        uint64 now_ = uint64(block.timestamp);
        address seed = _deploySeedDataRaw(257);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.BinCountExceedsLimit.selector, uint32(257), uint32(256)));
        sys.core.createMarket(0, 257, 1, now_ - 100, now_ + 10000, now_ + 10100, 257, WAD, address(sys.feePolicy), seed);
    }

    function test_allows_market_creation_with_numBins_256() public {
        uint64 now_ = uint64(block.timestamp);
        address seed = _deploySeedData(256);

        vm.prank(sys.owner);
        sys.core.createMarket(0, 256, 1, now_ - 100, now_ + 10000, now_ + 10100, 256, WAD, address(sys.feePolicy), seed);
    }

    function test_allows_market_creation_with_numBins_100() public {
        uint64 now_ = uint64(block.timestamp);
        address seed = _deploySeedData(100);

        vm.prank(sys.owner);
        sys.core.createMarket(0, 100, 1, now_ - 100, now_ + 10000, now_ + 10100, 100, WAD, address(sys.feePolicy), seed);
    }

    function test_allows_market_creation_with_numBins_2() public {
        uint64 now_ = uint64(block.timestamp);
        address seed = _deploySeedData(2);

        vm.prank(sys.owner);
        sys.core.createMarket(0, 2, 1, now_ - 100, now_ + 10000, now_ + 10100, 2, WAD, address(sys.feePolicy), seed);
    }

    function test_rejects_market_with_large_numBins_that_would_DoS_settlement() public {
        uint64 now_ = uint64(block.timestamp);
        // Create seed data for 256 bins (max), but pass numBins=1000 - seed data length mismatch
        address seed = _deploySeedDataRaw(256);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.SeedDataLengthMismatch.selector, 256 * 32, 1000 * 32));
        sys.core
            .createMarket(0, 1000, 1, now_ - 100, now_ + 10000, now_ + 10100, 1000, WAD, address(sys.feePolicy), seed);
    }

    // ============================================================
    // createMarketUniform also enforces cap
    // ============================================================

    function test_rejects_uniform_market_with_numBins_zero() public {
        uint64 now_ = uint64(block.timestamp);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.InvalidNumBins.selector, uint256(0)));
        sys.core.createMarketUniform(0, 10, 1, now_ - 100, now_ + 10000, now_ + 10100, 0, WAD, address(sys.feePolicy));
    }

    function test_rejects_uniform_market_with_numBins_gt_256() public {
        uint64 now_ = uint64(block.timestamp);

        vm.prank(sys.owner);
        vm.expectRevert(abi.encodeWithSelector(SE.BinCountExceedsLimit.selector, uint32(300), uint32(256)));
        sys.core
            .createMarketUniform(0, 300, 1, now_ - 100, now_ + 10000, now_ + 10100, 300, WAD, address(sys.feePolicy));
    }
}
