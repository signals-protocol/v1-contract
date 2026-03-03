import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployLazyMulSegmentTreeHarness } from "../../../helpers/deploy";
import { MAX_FACTOR, MIN_FACTOR } from "../../../helpers/constants";

/**
 * Gas benchmarks for LazyMulSegmentTree with recursive flush (SIG-294).
 *
 * Measures gas cost at different chunk counts to verify:
 * 1. Normal trades (1-5 chunks) have negligible overhead
 * 2. Large trades (10+ chunks) stay within Citrea 10M block gas limit
 */
describe("LazyMulSegmentTree – Gas Benchmark", () => {
  const NUM_BINS = 80;

  async function deploy80BinTree() {
    const harness = await deployLazyMulSegmentTreeHarness();
    await harness.init(NUM_BINS);
    return { harness };
  }

  describe("Full-range MAX_FACTOR applications", () => {
    const cases = [1, 3, 5, 10, 15, 20, 25];

    for (const count of cases) {
      it(`${count} full-range MAX_FACTOR application(s)`, async () => {
        const { harness } = await loadFixture(deploy80BinTree);

        let totalGas = 0n;
        for (let i = 0; i < count; i++) {
          const tx = await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
          const receipt = await tx.wait();
          totalGas += receipt!.gasUsed;
        }

        console.log(
          `      ${count} chunks: total=${totalGas.toLocaleString()} gas, avg=${(totalGas / BigInt(count)).toLocaleString()} gas/chunk`
        );

        // All must complete without revert
        const totalSum = await harness.getTotalSum();
        expect(totalSum).to.be.gt(0n);

        // No single chunk should exceed 5M gas (half of Citrea 10M block limit)
        expect(totalGas / BigInt(count)).to.be.lt(5_000_000n);
      });
    }
  });

  describe("Single-bin operations", () => {
    it("10 single-bin MAX_FACTOR applications", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      let totalGas = 0n;
      for (let i = 0; i < 10; i++) {
        const tx = await harness.applyRangeFactor(0, 0, MAX_FACTOR);
        const receipt = await tx.wait();
        totalGas += receipt!.gasUsed;
      }

      console.log(
        `      10 single-bin: total=${totalGas.toLocaleString()} gas, avg=${(totalGas / 10n).toLocaleString()} gas/chunk`
      );
      expect(totalGas / 10n).to.be.lt(500_000n);
    });
  });

  describe("Alternating factors (worst-case flush)", () => {
    it("10 alternating MAX/MIN factor cycles", async () => {
      const { harness } = await loadFixture(deploy80BinTree);

      let totalGas = 0n;
      for (let i = 0; i < 10; i++) {
        const txUp = await harness.applyRangeFactor(0, NUM_BINS - 1, MAX_FACTOR);
        const receiptUp = await txUp.wait();
        totalGas += receiptUp!.gasUsed;

        const txDown = await harness.applyRangeFactor(0, NUM_BINS - 1, MIN_FACTOR);
        const receiptDown = await txDown.wait();
        totalGas += receiptDown!.gasUsed;
      }

      console.log(
        `      20 ops (10 cycles): total=${totalGas.toLocaleString()} gas, avg=${(totalGas / 20n).toLocaleString()} gas/op`
      );
      expect(totalGas / 20n).to.be.lt(5_000_000n);
    });
  });
});
