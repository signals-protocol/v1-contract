import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployLazyMulSegmentTreeHarness } from "../../../helpers/deploy";
import { MAX_FACTOR } from "../../../helpers/constants";

/**
 * SIG-294: Reproduce Market 36 LazyFactorOverflow incident.
 *
 * Market 36 parameters:
 *   - numBins = 80, alpha = 10.7 WAD
 *   - maxSafeChunkQty = alpha × ln(100) ≈ 49.3 WAD → factor per chunk = 100e18 (MAX_FACTOR)
 *   - $990 trade → 990/49.3 ≈ 20 chunks of MAX_FACTOR applied to full range
 *
 * Root cause: _pushPendingFactor calls _applyFactorToNode on children,
 * which has NO flush logic → pendingFactor accumulates without bound → uint192 overflow.
 */
describe("LazyMulSegmentTree – Overflow Flush (SIG-294)", () => {
  const NUM_BINS = 80;

  async function deploy80BinTree() {
    const harness = await deployLazyMulSegmentTreeHarness();
    await harness.init(NUM_BINS);
    return { harness };
  }

  describe("Reproduction: full-range MAX_FACTOR overflow", () => {
    it("should survive 20+ full-range MAX_FACTOR applications without overflow", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      // Simulate $990 trade with alpha=10.7 WAD: 20 chunks of MAX_FACTOR
      const CHUNK_COUNT = 20;

      for (let i = 0; i < CHUNK_COUNT; i++) {
        await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
      }

      // After fix: totalSum and getRangeSum must return valid values
      const totalSum = await harness.getTotalSum();
      expect(totalSum).to.be.gt(0n);

      const rangeSum = await harness.getRangeSum(0, NUM_BINS - 1);
      expect(rangeSum).to.be.gt(0n);
    });

    it("should survive 25 full-range MAX_FACTOR applications (safety margin)", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      // 80-bin tree depth ≈ 7. Cascade reaches leaves on ~app 8.
      // Leaf can hold ~19 MAX_FACTOR pushes (100^19 × 1e18 ≈ 1e56 < uint192.max).
      // Safe limit ≈ 8 + 19 = 27 apps. Use 25 for margin.
      for (let i = 0; i < 25; i++) {
        await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
      }

      const totalSum = await harness.getTotalSum();
      expect(totalSum).to.be.gt(0n);
    });
  });

  describe("Regression: alternating up/down factors", () => {
    it("should handle alternating MAX/MIN factor on full range", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      const MIN_FACTOR = ethers.parseEther("0.01");

      // Alternating up/down stresses both FLUSH_THRESHOLD and UNDERFLOW_FLUSH_THRESHOLD paths
      for (let i = 0; i < 20; i++) {
        await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        await harness.applyRangeFactor(0, NUM_BINS - 1, MIN_FACTOR);
      }

      const totalSum = await harness.getTotalSum();
      expect(totalSum).to.be.gt(0n);
    });
  });

  describe("Edge: single-bin extreme", () => {
    it("should handle repeated MAX_FACTOR on a single bin (within leaf limit)", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      // Single-bin leaf can hold up to ~20 MAX_FACTOR before uint192 overflow
      // (100^20 × 1e18 ≈ 1e58 < uint192.max ≈ 6.28e57 — actually 100^19 ≈ 1e56 < 6.28e57)
      // Conservative: 15 applications should be safe
      for (let i = 0; i < 15; i++) {
        await harness.applyRangeFactor(0, 0, MAX_FACTOR);
      }

      const singleBinSum = await harness.getRangeSum(0, 0);
      expect(singleBinSum).to.be.gt(0n);

      // Other bins unaffected
      const restSum = await harness.getRangeSum(1, NUM_BINS - 1);
      expect(restSum).to.equal(ethers.parseEther("79")); // 79 WAD default
    });
  });

  describe("Sum consistency after recursive flush", () => {
    it("totalSum equals getRangeSum(0, size-1) after extreme factors", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      for (let i = 0; i < 15; i++) {
        await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
      }

      const totalSum = await harness.getTotalSum();
      const fullRangeSum = await harness.getRangeSum(0, NUM_BINS - 1);

      // Allow small rounding drift (at most ~254 wei per plan analysis)
      const drift = totalSum > fullRangeSum
        ? totalSum - fullRangeSum
        : fullRangeSum - totalSum;

      // Relative tolerance: 1e-12 of totalSum
      const maxDrift = totalSum / 1_000_000_000_000n + 1n;
      expect(drift).to.be.lte(maxDrift);
    });
  });

  describe("Limit probing: find exact failure thresholds", () => {
    it("single-bin: find MAX_FACTOR repetition limit before overflow", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      // With leaf pending fix: leaf pendingFactor stays ONE_WAD, only sum grows.
      // Limit is now uint256 sum overflow: 1e18 * 100^n > uint256.max ≈ 1.16e77
      // → n > 29.5 → overflow at MathMulOverflow around application 30
      let lastSuccess = 0;
      for (let i = 1; i <= 35; i++) {
        try {
          await harness.applyRangeFactor(0, 0, MAX_FACTOR);
          lastSuccess = i;
        } catch {
          console.log(`      Single-bin MAX_FACTOR: failed at application #${i} (last success: ${lastSuccess})`);
          // Verify it's a graceful revert, not a permanent brick
          // The tree should still be functional for OTHER bins
          const otherBinSum = await harness.getRangeSum(1, NUM_BINS - 1);
          expect(otherBinSum).to.be.gt(0n);
          // And the problematic bin should still be queryable (view function doesn't modify state)
          const bin0Sum = await harness.getRangeSum(0, 0);
          expect(bin0Sum).to.be.gt(0n);
          console.log(`      After revert: bin 0 sum=${bin0Sum}, other bins sum=${otherBinSum}`);
          console.log(`      Market NOT bricked: other operations still work`);
          return;
        }
      }
      console.log(`      Single-bin MAX_FACTOR: survived all 25 (unexpected)`);
    });

    it("full-range: find MAX_FACTOR repetition limit", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      let lastSuccess = 0;
      for (let i = 1; i <= 40; i++) {
        try {
          await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
          lastSuccess = i;
        } catch (e: any) {
          const reason = e.message?.includes("MathMulOverflow") ? "MathMulOverflow (sum uint256)" :
                         e.message?.includes("LazyFactorOverflow") ? "LazyFactorOverflow (pending uint192)" :
                         e.message?.includes("0x11") ? "Arithmetic overflow (panic)" :
                         "Unknown";
          console.log(`      Full-range MAX_FACTOR: failed at #${i} with ${reason} (last success: ${lastSuccess})`);

          // Verify graceful: tree still functional for queries
          const totalSum = await harness.getTotalSum();
          expect(totalSum).to.be.gt(0n);
          console.log(`      After revert: totalSum=${totalSum}, market NOT bricked`);
          return;
        }
      }
      console.log(`      Full-range MAX_FACTOR: survived all 40 (unexpected)`);
    });

    it("after leaf overflow revert, sell (MIN_FACTOR) on same bin recovers", async () => {
      const { harness } = await loadFixture(deploy80BinTree);
      const MIN_FACTOR = ethers.parseEther("0.01");

      // Push single bin to near-limit (15 is safe, 19 is limit)
      for (let i = 0; i < 18; i++) {
        await harness.applyRangeFactor(0, 0, MAX_FACTOR);
      }

      // Apply MIN_FACTOR (sell) to reduce pending
      await harness.applyRangeFactor(0, 0, MIN_FACTOR);

      // Now we can apply MORE MAX_FACTOR because the sell reduced pending
      await harness.applyRangeFactor(0, 0, MAX_FACTOR);

      const bin0Sum = await harness.getRangeSum(0, 0);
      expect(bin0Sum).to.be.gt(0n);
    });
  });

  describe("Factor loss detection: step-by-step verification", () => {
    it("each MAX_FACTOR application multiplies totalSum by exactly 100x (±rounding)", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      // Initial sum: 80 bins × 1 WAD = 80e18
      let prevSum = await harness.getTotalSum();
      expect(prevSum).to.equal(ethers.parseEther("80"));

      for (let i = 0; i < 20; i++) {
        await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        const curSum = await harness.getTotalSum();

        // Expected: prevSum × 100 (MAX_FACTOR = 100e18 = 100 WAD)
        // Allow relative tolerance of 1e-12 for rounding
        const expected = prevSum * 100n;
        const diff = curSum > expected ? curSum - expected : expected - curSum;
        const tolerance = expected / 1_000_000_000_000n + 1n;

        expect(diff).to.be.lte(
          tolerance,
          `Step ${i + 1}: sum=${curSum}, expected=${expected}, diff=${diff}`
        );

        prevSum = curSum;
      }
    });

    it("each MIN_FACTOR application divides totalSum by exactly 100x (±rounding)", async () => {
      const { harness } = await loadFixture(deploy80BinTree);
      const MIN_FACTOR = ethers.parseEther("0.01");

      let prevSum = await harness.getTotalSum();

      for (let i = 0; i < 10; i++) {
        await harness.applyRangeFactor(0, NUM_BINS - 1, MIN_FACTOR);
        const curSum = await harness.getTotalSum();

        // Expected: prevSum / 100
        const expected = prevSum / 100n;
        const diff = curSum > expected ? curSum - expected : expected - curSum;
        // Absolute tolerance: 1 wei per bin (rounding down per leaf)
        const tolerance = BigInt(NUM_BINS) + 1n;

        expect(diff).to.be.lte(
          tolerance,
          `Step ${i + 1}: sum=${curSum}, expected=${expected}, diff=${diff}`
        );

        prevSum = curSum;
      }
    });

    it("propagateLazy returns same sum as getRangeSum after flush cascade", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      // Build up enough pending to trigger recursive flush
      for (let i = 0; i < 10; i++) {
        await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
      }

      // getRangeSum is view (accumulates factors virtually)
      const viewSum = await harness.getRangeSum(0, NUM_BINS - 1);

      // propagateLazy writes pending down to leaves
      const propagatedSum = await harness.propagateLazy.staticCall(0, NUM_BINS - 1);

      const diff = viewSum > propagatedSum
        ? viewSum - propagatedSum
        : propagatedSum - viewSum;

      // Must match exactly or within 1 wei rounding per leaf node
      expect(diff).to.be.lte(BigInt(NUM_BINS));
    });

    it("individual bin sums add up to totalSum after recursive flush", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      for (let i = 0; i < 12; i++) {
        await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
      }

      // Force propagation to all leaves
      await harness.propagateLazy(0, NUM_BINS - 1);

      const totalSum = await harness.getTotalSum();

      // Sum each bin individually
      let leafSum = 0n;
      for (let bin = 0; bin < NUM_BINS; bin++) {
        leafSum += await harness.getRangeSum(bin, bin);
      }

      const drift = totalSum > leafSum ? totalSum - leafSum : leafSum - totalSum;
      const tolerance = totalSum / 1_000_000_000_000n + 1n;

      expect(drift).to.be.lte(
        tolerance,
        `totalSum=${totalSum}, leafSum=${leafSum}, drift=${drift}`
      );
    });
  });
});
