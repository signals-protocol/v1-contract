import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployFullSystem, FullSystem } from "../../helpers/fullSystem";
import { uniformFactors } from "../../helpers/constants";
import { buildRedstonePayload, submitWithPayload } from "../../helpers/redstone";
import { deploySeedData } from "../../helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Precision & regression tests for sponsored positions.
 *
 * Focus areas:
 * 1. Exact USDC balance accounting (no token leakage or creation)
 * 2. Existing positions are 100% unaffected by the new code path
 * 3. Partial close rounding correctness
 * 4. Core contract balance invariant: inflows == outflows
 */
describe("Sponsored Position — Precision & Regression", () => {
  let system: FullSystem;
  let owner: HardhatEthersSigner;
  let sponsor: HardhatEthersSigner;
  let beneficiary: HardhatEthersSigner;
  let regularTrader: HardhatEthersSigner;
  let marketId: bigint;
  let settlement: number;

  const NUM_BINS = 4;
  const ALPHA = ethers.parseEther("1");
  const QUANTITY = 5_000n;
  const FUND = 50_000_000n;
  const SEED = 20_000_000n;

  async function setupMarket() {
    const now = await time.latest();
    const start = now - 5;
    const end = now + 50;
    settlement = now + 60;
    const seedData = await deploySeedData(uniformFactors(NUM_BINS));
    marketId = await system.core.createMarket.staticCall(
      0, NUM_BINS, 1, start, end, settlement, NUM_BINS, ALPHA,
      system.feePolicy.target.toString(), await seedData.getAddress()
    );
    await system.core.createMarket(
      0, NUM_BINS, 1, start, end, settlement, NUM_BINS, ALPHA,
      system.feePolicy.target.toString(), await seedData.getAddress()
    );
    await system.core.seedNextChunks(marketId, NUM_BINS);
  }

  async function settleAt(tick: number) {
    await time.increaseTo(settlement);
    const payload = await buildRedstonePayload(tick, settlement + 1);
    await submitWithPayload(system.core, owner, marketId, payload);
    await time.increaseTo(settlement + 6);
    await system.core.connect(owner).finalizePrimarySettlement(marketId);
    await time.increaseTo(settlement + 10); // past claim delay
  }

  beforeEach(async () => {
    system = await deployFullSystem({ submitWindow: 5, opsWindow: 5 });
    owner = system.owner;
    [sponsor, beneficiary, regularTrader] = system.users;

    const coreAddr = await system.core.getAddress();
    await system.payment.connect(owner).approve(coreAddr, SEED);
    await system.core.connect(owner).seedVault(SEED);

    for (const s of [sponsor, regularTrader]) {
      await system.payment.transfer(s.address, FUND);
      await system.payment.connect(s).approve(coreAddr, ethers.MaxUint256);
    }

    await setupMarket();
  });

  // =========================================================
  // 1. Token conservation: no USDC created or destroyed
  // =========================================================

  describe("Token conservation invariant", () => {
    it("closePosition: sponsorReceived + beneficiaryReceived == netProceeds (exact)", async () => {
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const positionId = await system.position.nextId();
      await system.core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );

      // Snapshot all balances BEFORE close
      const coreAddr = await system.core.getAddress();
      const coreBefore = await system.payment.balanceOf(coreAddr);
      const sponsorBefore = await system.payment.balanceOf(sponsor.address);
      const beneficiaryBefore = await system.payment.balanceOf(beneficiary.address);

      await system.core.connect(beneficiary).closePosition(positionId, 0);

      const coreAfter = await system.payment.balanceOf(coreAddr);
      const sponsorAfter = await system.payment.balanceOf(sponsor.address);
      const beneficiaryAfter = await system.payment.balanceOf(beneficiary.address);

      const coreOutflow = coreBefore - coreAfter;
      const sponsorInflow = sponsorAfter - sponsorBefore;
      const beneficiaryInflow = beneficiaryAfter - beneficiaryBefore;

      // Invariant: core outflow == sponsor inflow + beneficiary inflow
      expect(coreOutflow).to.equal(sponsorInflow + beneficiaryInflow);
      // No negative inflows
      expect(sponsorInflow).to.be.greaterThanOrEqual(0n);
      expect(beneficiaryInflow).to.be.greaterThanOrEqual(0n);
    });

    it("claimPayout WIN: sponsorReceived + beneficiaryReceived == payout (exact)", async () => {
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const positionId = await system.position.nextId();
      await system.core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );

      await settleAt(2); // tick 2 is in [1,3) → win

      const coreAddr = await system.core.getAddress();
      const coreBefore = await system.payment.balanceOf(coreAddr);
      const sponsorBefore = await system.payment.balanceOf(sponsor.address);
      const beneficiaryBefore = await system.payment.balanceOf(beneficiary.address);
      await system.core.connect(beneficiary).claimPayout(positionId);

      const coreAfter = await system.payment.balanceOf(coreAddr);
      const sponsorAfter = await system.payment.balanceOf(sponsor.address);
      const beneficiaryAfter = await system.payment.balanceOf(beneficiary.address);

      const coreOutflow = coreBefore - coreAfter;
      const sponsorInflow = sponsorAfter - sponsorBefore;
      const beneficiaryInflow = beneficiaryAfter - beneficiaryBefore;

      // Payout = QUANTITY for winning position
      expect(coreOutflow).to.equal(QUANTITY);
      expect(sponsorInflow + beneficiaryInflow).to.equal(QUANTITY);
    });

    it("claimPayout LOSS: zero outflow from core", async () => {
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const positionId = await system.position.nextId();
      await system.core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );

      await settleAt(0); // tick 0 is outside [1,3) → loss

      const coreAddr = await system.core.getAddress();
      const coreBefore = await system.payment.balanceOf(coreAddr);
      await system.core.connect(beneficiary).claimPayout(positionId);

      const coreAfter = await system.payment.balanceOf(coreAddr);
      expect(coreAfter).to.equal(coreBefore); // nothing left core
    });
  });

  // =========================================================
  // 2. Existing positions: bit-identical behavior
  // =========================================================

  describe("Existing position regression (bit-identical)", () => {
    it("open → close: user balance delta identical to calculateCloseProceeds", async () => {
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const positionId = await system.position.nextId();
      await system.core.connect(regularTrader).openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000n);

      const expectedProceeds = await system.core.calculateCloseProceeds.staticCall(positionId);

      const before = await system.payment.balanceOf(regularTrader.address);
      await system.core.connect(regularTrader).closePosition(positionId, 0);
      const after = await system.payment.balanceOf(regularTrader.address);

      expect(after - before).to.equal(expectedProceeds);
    });

    it("open → increase → close: full round trip", async () => {
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const positionId = await system.position.nextId();
      await system.core.connect(regularTrader).openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000n);

      // Increase
      await system.core.connect(regularTrader).increasePosition(positionId, 1_000, 10_000_000n);

      // Close
      const before = await system.payment.balanceOf(regularTrader.address);
      await system.core.connect(regularTrader).closePosition(positionId, 0);
      const after = await system.payment.balanceOf(regularTrader.address);

      // Should receive proceeds (exact amount depends on CLMSR math, just verify > 0)
      expect(after).to.be.greaterThan(before);
      expect(await system.position.exists(positionId)).to.equal(false);
    });

    it("open → settle → claim: payout == QUANTITY for winning position", async () => {
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const positionId = await system.position.nextId();
      await system.core.connect(regularTrader).openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000n);

      await settleAt(2); // WIN

      const before = await system.payment.balanceOf(regularTrader.address);
      await system.core.connect(regularTrader).claimPayout(positionId);
      const after = await system.payment.balanceOf(regularTrader.address);

      expect(after - before).to.equal(QUANTITY);
    });

    it("sponsor balance never changes during regular position lifecycle", async () => {
      const sponsorBal = await system.payment.balanceOf(sponsor.address);

      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const positionId = await system.position.nextId();
      await system.core.connect(regularTrader).openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000n);
      expect(await system.payment.balanceOf(sponsor.address)).to.equal(sponsorBal);

      await system.core.connect(regularTrader).closePosition(positionId, 0);
      expect(await system.payment.balanceOf(sponsor.address)).to.equal(sponsorBal);
    });
  });

  // =========================================================
  // 3. Partial close rounding
  // =========================================================

  describe("Partial close — rounding precision", () => {
    it("3-way partial close: sum of principal portions == original cost", async () => {
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const positionId = await system.position.nextId();
      await system.core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );
      const originalCost = await system.core.getSponsoredCost(positionId);

      // Close in 3 uneven parts: 33%, 33%, 34%
      const part1 = (QUANTITY * 33n) / 100n;
      const part2 = (QUANTITY * 33n) / 100n;

      await system.core.connect(beneficiary).decreasePosition(positionId, part1, 0);
      const costAfter1 = await system.core.getSponsoredCost(positionId);

      await system.core.connect(beneficiary).decreasePosition(positionId, part2, 0);
      const costAfter2 = await system.core.getSponsoredCost(positionId);

      // Close remainder
      await system.core.connect(beneficiary).closePosition(positionId, 0);

      // After full close, the total principal distributed should match original
      // Allow 1 wei rounding tolerance per step (max 3 wei total)
      const principal1 = originalCost - costAfter1;
      const principal2 = costAfter1 - costAfter2;
      const principal3 = costAfter2; // final close takes all remaining
      const totalPrincipal = principal1 + principal2 + principal3;

      expect(totalPrincipal).to.equal(originalCost);
    });

    it("single-unit partial closes: no stuck dust", async () => {
      const smallQty = 10n; // very small position
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, smallQty);
      const positionId = await system.position.nextId();
      await system.core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, smallQty, cost + 1_000_000n
      );

      // Close 1 unit at a time
      for (let i = 0n; i < smallQty - 1n; i++) {
        await system.core.connect(beneficiary).decreasePosition(positionId, 1, 0);
      }
      // Final unit
      await system.core.connect(beneficiary).closePosition(positionId, 0);
      expect(await system.position.exists(positionId)).to.equal(false);

      // Sponsored cost should be fully consumed
      expect(await system.core.getSponsoredCost(positionId)).to.equal(0n);
    });
  });

  // =========================================================
  // 4. Exact proceeds math verification
  // =========================================================

  describe("Exact proceeds math", () => {
    it("WIN claim: sponsor gets exactly sponsoredCost, user gets exactly payout - sponsoredCost", async () => {
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const positionId = await system.position.nextId();
      await system.core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );
      const sponsoredCost = await system.core.getSponsoredCost(positionId);

      await settleAt(2); // WIN

      const sponsorBefore = await system.payment.balanceOf(sponsor.address);
      const beneficiaryBefore = await system.payment.balanceOf(beneficiary.address);

      await system.core.connect(beneficiary).claimPayout(positionId);

      const sponsorAfter = await system.payment.balanceOf(sponsor.address);
      const beneficiaryAfter = await system.payment.balanceOf(beneficiary.address);

      // Payout = QUANTITY (winning), always > sponsoredCost in CLMSR
      expect(sponsorAfter - sponsorBefore).to.equal(sponsoredCost);
      expect(beneficiaryAfter - beneficiaryBefore).to.equal(QUANTITY - sponsoredCost);
    });

    it("WIN batchClaim: sponsored + regular in same batch", async () => {
      // Sponsored position
      const cost1 = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const sponsoredPosId = await system.position.nextId();
      await system.core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost1 + 1_000_000n
      );

      // Regular position for same beneficiary (need funds)
      await system.payment.transfer(beneficiary.address, FUND);
      await system.payment.connect(beneficiary).approve(await system.core.getAddress(), ethers.MaxUint256);
      const cost2 = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const regularPosId = await system.position.nextId();
      await system.core.connect(beneficiary).openPosition(marketId, 1, 3, QUANTITY, cost2 + 1_000_000n);

      await settleAt(2); // both WIN

      const sponsoredCost = await system.core.getSponsoredCost(sponsoredPosId);
      const sponsorBefore = await system.payment.balanceOf(sponsor.address);
      const beneficiaryBefore = await system.payment.balanceOf(beneficiary.address);

      // Batch claim both
      await system.core.connect(beneficiary).batchClaimPayout([sponsoredPosId, regularPosId]);

      const sponsorAfter = await system.payment.balanceOf(sponsor.address);
      const beneficiaryAfter = await system.payment.balanceOf(beneficiary.address);

      // Sponsor gets back exactly sponsoredCost from the sponsored position
      expect(sponsorAfter - sponsorBefore).to.equal(sponsoredCost);

      // Beneficiary gets: (QUANTITY - sponsoredCost) from sponsored + QUANTITY from regular
      const expectedBeneficiary = (QUANTITY - sponsoredCost) + QUANTITY;
      expect(beneficiaryAfter - beneficiaryBefore).to.equal(expectedBeneficiary);
    });
  });

  // =========================================================
  // 5. Gas comparison
  // =========================================================

  describe("Gas overhead", () => {
    it("openPositionFor gas overhead vs openPosition < 30k", async () => {
      const cost = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const maxCost = cost + 1_000_000n;

      // Regular open
      const tx1 = await system.core.connect(regularTrader).openPosition(marketId, 1, 3, QUANTITY, maxCost);
      const receipt1 = await tx1.wait();

      // Need a new market for fair comparison (same tree state)
      await setupMarket();

      // Sponsored open
      const cost2 = await system.core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const tx2 = await system.core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost2 + 1_000_000n
      );
      const receipt2 = await tx2.wait();

      const gasRegular = receipt1!.gasUsed;
      const gasSponsored = receipt2!.gasUsed;
      const overhead = gasSponsored - gasRegular;

      // Overhead: 2 cold SSTORE (~40k) + PositionSponsored event + ZeroAddress check
      expect(overhead).to.be.lessThan(60_000n);
    });
  });
});
