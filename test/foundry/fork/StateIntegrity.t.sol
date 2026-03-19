// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./base/ForkBaseTest.sol";

/// @title StateIntegrity
/// @notice Smoke tests verifying that fork infrastructure works and on-chain state is readable.
///         If storage layout has drifted between deployed and current code, these reads revert
///         or return garbage — catching slot collisions before an upgrade.
contract StateIntegrityTest is ForkBaseTest {
    function test_proxy_implementations_exist() public view {
        // Verify ERC1967 impl slots point to deployed contracts
        address coreImpl = _implAddress(address(core));
        address positionImpl = _implAddress(address(position));
        address lpShareImpl = _implAddress(address(lpShare));

        assertTrue(coreImpl != address(0), "core impl is zero");
        assertTrue(positionImpl != address(0), "position impl is zero");
        assertTrue(lpShareImpl != address(0), "lpShare impl is zero");

        assertTrue(coreImpl.code.length > 0, "core impl has no code");
        assertTrue(positionImpl.code.length > 0, "position impl has no code");
        assertTrue(lpShareImpl.code.length > 0, "lpShare impl has no code");
    }

    function test_core_configuration_readable() public view {
        // Owner is set and is a contract (Safe)
        address owner = core.owner();
        assertTrue(owner != address(0), "core owner is zero");

        // Payment token exists
        address pt = address(core.paymentToken());
        assertTrue(pt != address(0), "payment token is zero");
        assertTrue(pt.code.length > 0, "payment token has no code");

        // All modules are set and have code
        assertTrue(core.tradeModule().code.length > 0, "trade module has no code");
        assertTrue(core.lifecycleModule().code.length > 0, "lifecycle module has no code");
        assertTrue(core.oracleModule().code.length > 0, "oracle module has no code");
        assertTrue(core.riskModule().code.length > 0, "risk module has no code");
        assertTrue(core.vaultModule().code.length > 0, "vault module has no code");

        // Position & LP share references
        assertTrue(address(core.positionContract()) != address(0), "position ref is zero");
        assertTrue(core.lpShareToken() != address(0), "lpShare ref is zero");
    }

    function test_position_state_readable() public view {
        uint256 nextId = position.nextId();
        assertGe(nextId, 1, "nextId should be >= 1");
        assertEq(position.name(), "Signals Position", "position name mismatch");
    }

    function test_vault_state_readable() public view {
        assertGt(core.getVaultPrice(), 0, "vault price should be > 0");
        assertGt(core.getVaultNav(), 0, "vault nav should be > 0");
        assertGt(core.getVaultShares(), 0, "vault shares should be > 0");
    }

    function test_market_state_readable() public view {
        uint256 nextMarketId = core.nextMarketId();
        if (nextMarketId > 0) {
            MarketSnapshot memory mkt = _readMarket(1);
            assertTrue(mkt.isSeeded, "first market should be seeded");
            assertGt(mkt.numBins, 0, "first market numBins should be > 0");
            assertGt(mkt.liquidityParameter, 0, "first market liquidityParameter should be > 0");
        }
    }

    function test_batch_state_readable() public view {
        assertGt(core.getCurrentBatchId(), 0, "current batch ID should be > 0");
    }
}
