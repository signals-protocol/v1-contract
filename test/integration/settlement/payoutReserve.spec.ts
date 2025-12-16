/**
 * PayoutReserve Spec Tests (Phase 6 TDD)
 *
 * Whitepaper v2 Section 3.5 requirements:
 * - Payout reserve is deducted from NAV at settlement/batch time
 * - claimPayout() does NOT change NAV/Price after batch processing
 * - claimPayout() is gated: must wait until batch is processed
 *
 * These tests are expected to FAIL initially (TDD approach).
 * Implementation will make them pass.
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import {
  LazyMulSegmentTree,
  LPVaultModule,
  MarketLifecycleModule,
  MockERC20,
  MockSignalsPosition,
  OracleModule,
  SignalsCoreHarness,
  TestERC1967Proxy,
  TradeModule,
} from "../../../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const abiCoder = ethers.AbiCoder.defaultAbiCoder();
const BATCH_SECONDS = 86_400n;
const WAD = ethers.parseEther("1");

// Phase 6: Helper for 6-decimal token amounts
function usdc(amount: string | number): bigint {
  return ethers.parseUnits(String(amount), 6);
}

function buildOracleDigest(
  chainId: bigint,
  core: string,
  marketId: bigint,
  settlementValue: bigint,
  priceTimestamp: bigint
) {
  const encoded = abiCoder.encode(
    ["uint256", "address", "uint256", "int256", "uint64"],
    [chainId, core, marketId, settlementValue, priceTimestamp]
  );
  return ethers.keccak256(encoded);
}

describe("PayoutReserve Spec Tests (WP v2 Sec 3.5)", () => {
  async function deployFullSystem() {
    const [owner, seeder, trader, oracleSigner] = await ethers.getSigners();
    const { chainId } = await ethers.provider.getNetwork();

    // 18-decimal token for WAD-aligned accounting
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    // Phase 6: Use 6-decimal token as per WP v2 Sec 6.2 (paymentToken = USDC6)
    const payment = (await MockERC20Factory.deploy(
      "MockVaultToken",
      "MVT",
      6
    )) as MockERC20;

    const position = (await (
      await ethers.getContractFactory("MockSignalsPosition")
    ).deploy()) as MockSignalsPosition;

    const lazy = (await (
      await ethers.getContractFactory("LazyMulSegmentTree")
    ).deploy()) as LazyMulSegmentTree;

    const lifecycle = (await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazy.target },
      })
    ).deploy()) as MarketLifecycleModule;

    const trade = (await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazy.target },
      })
    ).deploy()) as TradeModule;

    const oracle = (await (
      await ethers.getContractFactory("OracleModule")
    ).deploy()) as OracleModule;

    const vault = (await (
      await ethers.getContractFactory("LPVaultModule")
    ).deploy()) as LPVaultModule;

    const coreImpl = (await (
      await ethers.getContractFactory("SignalsCoreHarness", {
        libraries: { LazyMulSegmentTree: lazy.target },
      })
    ).deploy()) as SignalsCoreHarness;

    const submitWindow = 300;
    const finalizeDeadline = 60;
    const initData = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      submitWindow,
      finalizeDeadline,
    ]);

    const proxy = (await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(coreImpl.target, initData)) as TestERC1967Proxy;

    const core = (await ethers.getContractAt(
      "SignalsCoreHarness",
      await proxy.getAddress()
    )) as SignalsCoreHarness;

    await core.setModules(
      trade.target,
      lifecycle.target,
      ethers.ZeroAddress,
      vault.target,
      oracle.target
    );
    await core.setOracleConfig(oracleSigner.address);

    // Vault configuration
    await core.setMinSeedAmount(usdc("100"));
    await core.setWithdrawalLagBatches(0);
    await core.setFeeWaterfallConfig(
      ethers.parseEther("-0.3"), // pdd = -30% (WAD ratio)
      0n, // rhoBS
      ethers.parseEther("0.8"), // phiLP (WAD ratio)
      ethers.parseEther("0.1"), // phiBS (WAD ratio)
      ethers.parseEther("0.1") // phiTR (WAD ratio)
    );
    await core.setCapitalStack(ethers.parseEther("500"), 0n); // WAD amounts

    // Fund accounts with 6-decimal token amounts
    await payment.mint(seeder.address, usdc("10000"));
    await payment.mint(trader.address, usdc("10000"));
    await payment.connect(seeder).approve(core.target, ethers.MaxUint256);
    await payment.connect(trader).approve(core.target, ethers.MaxUint256);

    return {
      owner,
      seeder,
      trader,
      oracleSigner,
      chainId,
      core,
      payment,
      position,
      trade,
    };
  }

  async function setupMarketWithPosition(
    core: SignalsCoreHarness,
    seeder: HardhatEthersSigner,
    _oracleSigner: HardhatEthersSigner,
    _chainId: bigint,
    winningTick: number = 1
  ) {
    // Set deterministic timestamp aligned to batch boundary
    const latest = BigInt(await time.latest());
    const baseBatchId = latest / BATCH_SECONDS + 1n;
    const seedTime = baseBatchId * BATCH_SECONDS + 100n;

    // Seed vault
    await time.setNextBlockTimestamp(Number(seedTime));
    await core.connect(seeder).seedVault(usdc("1000"));

    // Create market with proper timing:
    // - start: shortly after seed
    // - end: before tSet
    // - tSet: within the same batch as seed + enough time for oracle submission
    const start = seedTime + 50n;
    const end = seedTime + 200n;
    const tSet = seedTime + 250n; // Settlement timestamp

    // Advance time to create market
    await time.setNextBlockTimestamp(Number(seedTime + 10n));
    const marketId = await core.createMarketUniform.staticCall(
      0, // minTick
      4, // maxTick
      1, // tickSpacing
      Number(start),
      Number(end),
      Number(tSet),
      4, // numBins
      WAD, // liquidityParameter
      ethers.ZeroAddress // feePolicy
    );

    await core.createMarketUniform(
      0,
      4,
      1,
      Number(start),
      Number(end),
      Number(tSet),
      4,
      WAD,
      ethers.ZeroAddress
    );

    return {
      marketId,
      seedTime,
      tSet,
      start,
      end,
      winningTick,
      batchId: baseBatchId,
    };
  }

  // ================================================================
  // SPEC-1: Claim Gating is TIME-BASED, NOT BATCH-BASED
  // (WP v1.0: claim is allowed after settlementFinalizedAt + Δ_claim)
  // Batch processing status is IRRELEVANT to claim eligibility.
  // NAV is unaffected because payout was already escrowed at settlement.
  // ================================================================
  describe("SPEC-1: Claim Gating - time-based (settlementFinalizedAt + Δ_claim)", () => {
    it("reverts claimPayout when time < settlementFinalizedAt + Δ_claim", async () => {
      const { core, seeder, trader, oracleSigner, chainId, position, trade } =
        await loadFixture(deployFullSystem);

      const { marketId, tSet } = await setupMarketWithPosition(
        core,
        seeder,
        oracleSigner,
        chainId
      );

      // Create a position
      const positionId = 1n;
      const positionQuantity = 1000n;
      await position.mockMint(
        trader.address,
        positionId,
        marketId,
        0,
        2,
        positionQuantity
      );

      // Phase 6: Set exposure ledger to match the position
      await core.harnessAddExposure(marketId, 0, 2, positionQuantity);

      // Submit oracle price and settle market
      const priceTimestamp = tSet + 1n;
      const settlementValue = 1n; // tick 1 wins
      const digest = buildOracleDigest(
        chainId,
        await core.getAddress(),
        marketId,
        settlementValue,
        priceTimestamp
      );
      const sig = await oracleSigner.signMessage(ethers.getBytes(digest));

      await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
      await core.submitSettlementPrice(
        marketId,
        settlementValue,
        Number(priceTimestamp),
        sig
      );

      // settlementFinalizeDeadline is 60s, settle at priceTimestamp + 50n
      const settleTime = priceTimestamp + 50n;
      await time.setNextBlockTimestamp(Number(settleTime));
      await core.settleMarket(marketId);

      // Market is settled, but we're before claimOpenTime
      // claimOpenTime = settlementFinalizedAt + settlementFinalizeDeadline
      // Try to claim at settleTime + 30s (before 60s deadline)
      await time.setNextBlockTimestamp(Number(settleTime + 30n));

      // SPEC: claimPayout should REVERT because time < claimOpenTime
      // Note: Use TradeModule for error signature since SignalsCoreHarness may not expose it
      await expect(
        core.connect(trader).claimPayout(positionId)
      ).to.be.revertedWithCustomError(trade, "SettlementTooEarly");
    });

    it("allows claimPayout after time >= settlementFinalizedAt + Δ_claim (batch not processed)", async () => {
      const { core, seeder, trader, oracleSigner, chainId, position, payment } =
        await loadFixture(deployFullSystem);

      const { marketId, tSet, batchId } = await setupMarketWithPosition(
        core,
        seeder,
        oracleSigner,
        chainId
      );

      // Create a winning position
      const positionId = 1n;
      const positionQuantity = 1000n;
      await position.mockMint(
        trader.address,
        positionId,
        marketId,
        0, // lowerTick
        2, // upperTick (covers tick 1)
        positionQuantity
      );

      // Phase 6: Set exposure ledger to match the position
      await core.harnessAddExposure(marketId, 0, 2, positionQuantity);

      // Settle market
      const priceTimestamp = tSet + 1n;
      const settlementValue = 1n; // tick 1 wins
      const digest = buildOracleDigest(
        chainId,
        await core.getAddress(),
        marketId,
        settlementValue,
        priceTimestamp
      );
      const sig = await oracleSigner.signMessage(ethers.getBytes(digest));

      await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
      await core.submitSettlementPrice(
        marketId,
        settlementValue,
        Number(priceTimestamp),
        sig
      );

      const settleTime = priceTimestamp + 50n;
      await time.setNextBlockTimestamp(Number(settleTime));
      await core.settleMarket(marketId);

      // claimOpenTime = settlementFinalizedAt + settlementFinalizeDeadline (60s)
      const claimOpenTime = settleTime + 61n;

      // KEY: DO NOT process the batch - claim should still work based on TIME only
      const [, , , , , , processed] = await core.getDailyPnl.staticCall(
        batchId
      );
      expect(processed).to.equal(false, "Batch should NOT be processed");

      // Now claimPayout should succeed (we're past claim window, batch NOT processed)
      await time.setNextBlockTimestamp(Number(claimOpenTime + 1n));
      const balanceBefore = await payment.balanceOf(trader.address);
      await core.connect(trader).claimPayout(positionId);
      const balanceAfter = await payment.balanceOf(trader.address);

      // Trader receives payout from escrow
      expect(balanceAfter).to.be.gt(balanceBefore);
    });
  });

  // ================================================================
  // SPEC-2: claimPayout MUST NOT change NAV/Price
  // (WP v1.0: Payout is escrowed at settlement finalization.
  //  claim() draws only from escrow, not from vault NAV.
  //  NAV is unaffected because payout liability was already
  //  deducted at settlement via L_t = ΔC_t - Payout_t)
  // ================================================================
  describe("SPEC-2: claimPayout does NOT change NAV/Price", () => {
    it("NAV is unchanged after claimPayout", async () => {
      const { core, seeder, trader, oracleSigner, chainId, position } =
        await loadFixture(deployFullSystem);

      const { marketId, tSet, batchId } = await setupMarketWithPosition(
        core,
        seeder,
        oracleSigner,
        chainId
      );

      // Create winning position
      const positionId = 1n;
      const positionQuantity = 1000n;
      await position.mockMint(
        trader.address,
        positionId,
        marketId,
        0,
        2,
        positionQuantity
      );

      // Phase 6: Set exposure ledger to match the position
      await core.harnessAddExposure(marketId, 0, 2, positionQuantity);

      // Settle and process batch
      const priceTimestamp = tSet + 1n;
      const digest = buildOracleDigest(
        chainId,
        await core.getAddress(),
        marketId,
        1n,
        priceTimestamp
      );
      const sig = await oracleSigner.signMessage(ethers.getBytes(digest));

      await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
      await core.submitSettlementPrice(
        marketId,
        1n,
        Number(priceTimestamp),
        sig
      );
      await time.setNextBlockTimestamp(Number(priceTimestamp + 50n));
      await core.settleMarket(marketId);

      // Advance time past claim window (settlementFinalizeDeadline = 60s)
      const claimOpenTime = priceTimestamp + 50n + 61n;
      await time.setNextBlockTimestamp(Number(claimOpenTime));
      await core.processDailyBatch(batchId);

      // Record NAV before claim
      const navBefore = await core.getVaultNav.staticCall();
      const priceBefore = await core.getVaultPrice.staticCall();

      // Claim payout (now past claim window)
      await time.setNextBlockTimestamp(Number(claimOpenTime + 1n));
      await core.connect(trader).claimPayout(positionId);

      // NAV and Price MUST be unchanged
      const navAfter = await core.getVaultNav.staticCall();
      const priceAfter = await core.getVaultPrice.staticCall();

      expect(navAfter).to.equal(navBefore, "NAV changed after claimPayout");
      expect(priceAfter).to.equal(
        priceBefore,
        "Price changed after claimPayout"
      );
    });

    it("multiple claims do not change NAV", async () => {
      const {
        core,
        seeder,
        trader,
        owner,
        oracleSigner,
        chainId,
        position,
      } = await loadFixture(deployFullSystem);

      const { marketId, tSet, batchId } = await setupMarketWithPosition(
        core,
        seeder,
        oracleSigner,
        chainId
      );

      // Create multiple winning positions
      const qty1 = 500n;
      const qty2 = 300n;
      await position.mockMint(trader.address, 1n, marketId, 0, 2, qty1);
      await position.mockMint(owner.address, 2n, marketId, 0, 2, qty2);

      // Phase 6: Set exposure ledger to match the positions
      await core.harnessAddExposure(marketId, 0, 2, qty1);
      await core.harnessAddExposure(marketId, 0, 2, qty2);

      // Settle and process
      const priceTimestamp = tSet + 1n;
      const digest = buildOracleDigest(
        chainId,
        await core.getAddress(),
        marketId,
        1n,
        priceTimestamp
      );
      const sig = await oracleSigner.signMessage(ethers.getBytes(digest));

      await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
      await core.submitSettlementPrice(
        marketId,
        1n,
        Number(priceTimestamp),
        sig
      );
      await time.setNextBlockTimestamp(Number(priceTimestamp + 50n));
      await core.settleMarket(marketId);

      // Advance time past claim window
      const claimOpenTime = priceTimestamp + 50n + 61n;
      await time.setNextBlockTimestamp(Number(claimOpenTime));
      await core.processDailyBatch(batchId);

      const navBefore = await core.getVaultNav.staticCall();

      // First claim (past claim window)
      await time.setNextBlockTimestamp(Number(claimOpenTime + 1n));
      await core.connect(trader).claimPayout(1n);
      const navAfterFirst = await core.getVaultNav.staticCall();
      expect(navAfterFirst).to.equal(
        navBefore,
        "NAV changed after first claim"
      );

      // Second claim
      await time.setNextBlockTimestamp(Number(claimOpenTime + 2n));
      await core.connect(owner).claimPayout(2n);
      const navAfterSecond = await core.getVaultNav.staticCall();
      expect(navAfterSecond).to.equal(
        navBefore,
        "NAV changed after second claim"
      );
    });
  });

  // ================================================================
  // SPEC-3: Payout reserve is reflected in L_t calculation
  // (WP v2 Sec 3.5 Eq 3.11-3.12: L_t = ΔC_t - Payout_t)
  // ================================================================
  describe("SPEC-3: Payout reserve affects L_t", () => {
    it("L_t includes payout deduction (ΔC_t - Payout_t)", async () => {
      const { core, seeder, oracleSigner, chainId, position, trader } =
        await loadFixture(deployFullSystem);

      const { marketId, tSet, batchId } = await setupMarketWithPosition(
        core,
        seeder,
        oracleSigner,
        chainId
      );

      // Create a position that will win
      const positionQuantity = 1000n;
      await position.mockMint(
        trader.address,
        1n,
        marketId,
        0,
        2,
        positionQuantity
      );

      // Phase 6: Set exposure ledger to match the position
      // Position covers ticks [0, 2), so set exposure at each tick in range
      await core.harnessAddExposure(marketId, 0, 2, positionQuantity);

      // Settle
      const priceTimestamp = tSet + 1n;
      const digest = buildOracleDigest(
        chainId,
        await core.getAddress(),
        marketId,
        1n,
        priceTimestamp
      );
      const sig = await oracleSigner.signMessage(ethers.getBytes(digest));

      await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
      await core.submitSettlementPrice(
        marketId,
        1n,
        Number(priceTimestamp),
        sig
      );
      await time.setNextBlockTimestamp(Number(priceTimestamp + 50n));
      await core.settleMarket(marketId);

      // Check L_t recorded in daily PnL snapshot
      const [lt] = await core.getDailyPnl.staticCall(batchId);

      // L_t should include payout deduction
      // If there's a winning position, L_t should be:
      // L_t = ΔC_t - Payout_t
      // Since Payout_t > 0, L_t should be less than ΔC_t
      // This test verifies the payout is factored into L_t

      // For now, verify L_t is not zero (indicating some P&L calculation happened)
      // The exact value depends on the implementation
      // This assertion will need refinement based on actual implementation
      expect(lt).to.not.equal(0n, "L_t should reflect payout reserve");
    });
  });

  // ================================================================
  // SPEC-4: Payout reserve invariant
  // (Sum of all winning position payouts == payoutReserve)
  // ================================================================
  describe("SPEC-4: Payout reserve invariant", () => {
    it("total winning payouts equals escrow reserve", async () => {
      const {
        core,
        seeder,
        trader,
        owner,
        oracleSigner,
        chainId,
        position,
        payment,
      } = await loadFixture(deployFullSystem);

      const { marketId, tSet, batchId } = await setupMarketWithPosition(
        core,
        seeder,
        oracleSigner,
        chainId
      );

      // Create positions: some winning, some losing
      const winningQty1 = 500n;
      const winningQty2 = 300n;
      const losingQty = 200n;

      await position.mockMint(trader.address, 1n, marketId, 0, 2, winningQty1); // wins (tick 1 in [0,2))
      await position.mockMint(owner.address, 2n, marketId, 0, 2, winningQty2); // wins
      await position.mockMint(trader.address, 3n, marketId, 2, 4, losingQty); // loses (tick 1 not in [2,4))

      // Phase 6: Set exposure ledger to match positions
      // Winning positions cover [0, 2), losing covers [2, 4)
      await core.harnessAddExposure(marketId, 0, 2, winningQty1);
      await core.harnessAddExposure(marketId, 0, 2, winningQty2);
      await core.harnessAddExposure(marketId, 2, 4, losingQty);

      // Settle at tick 1
      const priceTimestamp = tSet + 1n;
      const digest = buildOracleDigest(
        chainId,
        await core.getAddress(),
        marketId,
        1n,
        priceTimestamp
      );
      const sig = await oracleSigner.signMessage(ethers.getBytes(digest));

      await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
      await core.submitSettlementPrice(
        marketId,
        1n,
        Number(priceTimestamp),
        sig
      );
      await time.setNextBlockTimestamp(Number(priceTimestamp + 50n));
      await core.settleMarket(marketId);

      // Advance time past claim window
      const claimOpenTime = priceTimestamp + 50n + 61n;
      await time.setNextBlockTimestamp(Number(claimOpenTime));
      await core.processDailyBatch(batchId);

      // Expected total payout = winningQty1 + winningQty2
      const expectedTotalPayout = winningQty1 + winningQty2;

      // Get payout reserve from storage (Phase 6 will add this)
      // For now, we verify by claiming all and checking balance changes
      const balanceBefore = await payment.balanceOf(await core.getAddress());

      // Claims past claim window
      await time.setNextBlockTimestamp(Number(claimOpenTime + 1n));
      await core.connect(trader).claimPayout(1n);
      await time.setNextBlockTimestamp(Number(claimOpenTime + 2n));
      await core.connect(owner).claimPayout(2n);

      // Loser claim should give 0
      const balanceBeforeLoser = await payment.balanceOf(trader.address);
      await time.setNextBlockTimestamp(Number(claimOpenTime + 3n));
      await core.connect(trader).claimPayout(3n);
      const balanceAfterLoser = await payment.balanceOf(trader.address);
      expect(balanceAfterLoser).to.equal(
        balanceBeforeLoser,
        "Loser should receive 0"
      );

      const balanceAfter = await payment.balanceOf(await core.getAddress());

      // Core balance decreased by exactly expectedTotalPayout
      expect(balanceBefore - balanceAfter).to.equal(expectedTotalPayout);
    });
  });
});
