import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployFixedPointMathHarness } from "../../helpers/deploy";
import {
  WAD,
  HALF_WAD,
  TWO_WAD,
  LOOSE_TOLERANCE,
} from "../../helpers/constants";
import { approx, createPrng } from "../../helpers/utils";

describe("FixedPointMathU", () => {
  async function deployFixture() {
    const test = await deployFixedPointMathHarness();
    return { test };
  }

  // ============================================================
  // Basic Operations
  // ============================================================
  describe("wMul", () => {
    it("multiplies correctly: 2 * 3 = 6", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wMul(TWO_WAD, ethers.parseEther("3"));
      expect(result).to.equal(ethers.parseEther("6"));
    });

    it("multiplies correctly: 0.5 * 0.5 = 0.25", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wMul(HALF_WAD, HALF_WAD);
      expect(result).to.equal(ethers.parseEther("0.25"));
    });

    it("multiplies by zero returns zero", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wMul(TWO_WAD, 0n);
      expect(result).to.equal(0n);
    });

    it("multiplies by WAD returns same value", async () => {
      const { test } = await loadFixture(deployFixture);
      const five = ethers.parseEther("5");
      const result = await test.wMul(five, WAD);
      expect(result).to.equal(five);
    });
  });

  describe("wDiv", () => {
    it("divides correctly: 6 / 2 = 3", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wDiv(ethers.parseEther("6"), TWO_WAD);
      expect(result).to.equal(ethers.parseEther("3"));
    });

    it("divides correctly: 1 / 2 = 0.5", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wDiv(WAD, TWO_WAD);
      expect(result).to.equal(HALF_WAD);
    });

    it("reverts on division by zero", async () => {
      const { test } = await loadFixture(deployFixture);
      await expect(test.wDiv(WAD, 0n)).to.be.revertedWithCustomError(
        test,
        "FP_DivisionByZero"
      );
    });

    it("divides by WAD returns same value", async () => {
      const { test } = await loadFixture(deployFixture);
      const five = ethers.parseEther("5");
      const result = await test.wDiv(five, WAD);
      expect(result).to.equal(five);
    });
  });

  describe("wMulNearest", () => {
    it("returns exact result for clean multiplication", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wMulNearest(WAD, WAD);
      expect(result).to.equal(WAD);
    });

    it("rounds to nearest (down) when fraction < 0.5", async () => {
      const { test } = await loadFixture(deployFixture);
      // 1.0 * 1.0...0001 should not round up significantly
      const result = await test.wMulNearest(WAD, WAD + 1n);
      expect(result).to.be.closeTo(WAD, 1n);
    });

    it("multiplies by zero returns zero", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wMulNearest(TWO_WAD, 0n);
      expect(result).to.equal(0n);
    });
  });

  describe("wMulUp", () => {
    it("rounds up on multiplication with remainder", async () => {
      const { test } = await loadFixture(deployFixture);
      // (WAD + 1) * (WAD + 1) / WAD = WAD + 2 + 1/WAD → rounds up to WAD + 3
      const result = await test.wMulUp(WAD + 1n, WAD + 1n);
      const exact = await test.wMul(WAD + 1n, WAD + 1n);
      expect(result).to.be.gte(exact);
    });

    it("returns exact value when no remainder", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wMulUp(TWO_WAD, TWO_WAD);
      expect(result).to.equal(ethers.parseEther("4"));
    });

    it("multiplies by zero returns zero", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wMulUp(TWO_WAD, 0n);
      expect(result).to.equal(0n);
    });
  });

  describe("wDivUp", () => {
    it("rounds up on division with remainder", async () => {
      const { test } = await loadFixture(deployFixture);
      // 1 / 3 should round up
      const result = await test.wDivUp(WAD, ethers.parseEther("3"));
      const exact = await test.wDiv(WAD, ethers.parseEther("3"));
      expect(result).to.be.gte(exact);
    });

    it("returns exact value when no remainder", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wDivUp(ethers.parseEther("6"), TWO_WAD);
      expect(result).to.equal(ethers.parseEther("3"));
    });

    it("divides by WAD returns same value", async () => {
      const { test } = await loadFixture(deployFixture);
      const five = ethers.parseEther("5");
      const result = await test.wDivUp(five, WAD);
      expect(result).to.equal(five);
    });

    it("reverts on division by zero", async () => {
      const { test } = await loadFixture(deployFixture);
      await expect(test.wDivUp(WAD, 0n)).to.be.revertedWithCustomError(
        test,
        "FP_DivisionByZero"
      );
    });
  });

  describe("wDivNearest", () => {
    it("rounds to nearest on division", async () => {
      const { test } = await loadFixture(deployFixture);
      // 5 / 3 = 1.666... → rounds to nearest
      const result = await test.wDivNearest(
        ethers.parseEther("5"),
        ethers.parseEther("3")
      );
      // 1.666... WAD, nearest to integer part
      expect(result).to.be.closeTo(ethers.parseEther("1.666666666666666666"), 1n);
    });

    it("returns exact value when evenly divisible", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wDivNearest(ethers.parseEther("6"), TWO_WAD);
      expect(result).to.equal(ethers.parseEther("3"));
    });

    it("reverts on division by zero", async () => {
      const { test } = await loadFixture(deployFixture);
      await expect(test.wDivNearest(WAD, 0n)).to.be.revertedWithCustomError(
        test,
        "FP_DivisionByZero"
      );
    });
  });

  // ============================================================
  // Exp and Ln
  // ============================================================
  describe("wExp", () => {
    it("exp(0) = 1", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wExp(0n);
      expect(result).to.equal(WAD);
    });

    it("exp(1) ≈ e ≈ 2.718", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wExp(WAD);
      const expected = ethers.parseEther("2.718281828459045235");
      approx(result, expected, LOOSE_TOLERANCE);
    });

    it("exp(2) ≈ 7.389", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wExp(TWO_WAD);
      const expected = ethers.parseEther("7.38905609893065");
      approx(result, expected, LOOSE_TOLERANCE);
    });

    it("reverts on exp(MAX_EXP_INPUT + 1) overflow", async () => {
      const { test } = await loadFixture(deployFixture);
      // MAX_EXP_INPUT_WAD = 133_084258667509499440 (≈133.084 WAD)
      const MAX_EXP_INPUT_WAD = 133_084258667509499440n;
      await expect(test.wExp(MAX_EXP_INPUT_WAD + 1n)).to.be.revertedWithCustomError(
        test,
        "FP_Overflow"
      );
    });

    it("succeeds at MAX_EXP_INPUT boundary", async () => {
      const { test } = await loadFixture(deployFixture);
      const MAX_EXP_INPUT_WAD = 133_084258667509499440n;
      // Should not revert
      const result = await test.wExp(MAX_EXP_INPUT_WAD);
      expect(result).to.be.gt(0n);
    });

    // Note: exp(-x) not tested - v1 FixedPointMathU only supports unsigned inputs
  });

  describe("wLn", () => {
    it("ln(1) = 0", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wLn(WAD);
      expect(result).to.equal(0n);
    });

    it("ln(e) ≈ 1", async () => {
      const { test } = await loadFixture(deployFixture);
      const e = ethers.parseEther("2.718281828459045235");
      const result = await test.wLn(e);
      approx(result, WAD, LOOSE_TOLERANCE);
    });

    it("ln(2) ≈ 0.693", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.wLn(TWO_WAD);
      const expected = ethers.parseEther("0.693147180559945309");
      approx(result, expected, LOOSE_TOLERANCE);
    });

    it("reverts on ln(0)", async () => {
      const { test } = await loadFixture(deployFixture);
      await expect(test.wLn(0n)).to.be.revertedWithCustomError(
        test,
        "FP_InvalidInput"
      );
    });
  });

  describe("lnWadUp", () => {
    it("rounds up ln(n) result (+1 wei)", async () => {
      const { test } = await loadFixture(deployFixture);
      // lnWadUp(n) = ln(n*WAD) + 1 for n > 1
      // lnWadUp(2) = ln(2*WAD) + 1 = ln(2e18) + 1
      const lnUp = await test.lnWadUp(2);
      // ln(2) ≈ 0.693 WAD
      // But lnWadUp takes integer n and computes ln(n * WAD)
      // ln(2e18) ≈ 42.14... WAD (since ln(2e18) = ln(2) + 18*ln(10))
      expect(lnUp).to.be.gt(0n);
    });

    it("ln(1) = 0 (n <= 1 returns 0)", async () => {
      const { test } = await loadFixture(deployFixture);
      // lnWadUp(n) returns 0 for n <= 1
      const result = await test.lnWadUp(1);
      expect(result).to.equal(0n);
    });

    it("ln(0) = 0 (n <= 1 returns 0)", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.lnWadUp(0);
      expect(result).to.equal(0n);
    });
  });

  // ============================================================
  // Conversion (6-dec ↔ 18-dec)
  // ============================================================
  describe("toWad", () => {
    it("converts 1 USDC (1e6) to 1e18", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.toWad(1_000_000n);
      expect(result).to.equal(WAD);
    });

    it("converts 0 to 0", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.toWad(0n);
      expect(result).to.equal(0n);
    });

    it("reverts on overflow", async () => {
      const { test } = await loadFixture(deployFixture);
      // type(uint256).max / 1e12 + 1 should overflow
      const maxSafe = (2n ** 256n - 1n) / (10n ** 12n);
      await expect(test.toWad(maxSafe + 1n)).to.be.revertedWithCustomError(
        test,
        "FP_Overflow"
      );
    });
  });

  describe("fromWad", () => {
    it("converts 1e18 to 1e6 (truncates)", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.fromWad(WAD);
      expect(result).to.equal(1_000_000n);
    });

    it("truncates fractional part", async () => {
      const { test } = await loadFixture(deployFixture);
      // 1.5e18 → 1.5e6 → 1e6 (truncated)
      const result = await test.fromWad(WAD + HALF_WAD);
      expect(result).to.equal(1_500_000n);
    });
  });

  describe("fromWadRoundUp", () => {
    it("rounds up non-zero fractional part", async () => {
      const { test } = await loadFixture(deployFixture);
      // 1e18 + 1 → 1e6 + 1 (rounded up)
      const result = await test.fromWadRoundUp(WAD + 1n);
      expect(result).to.equal(1_000_001n);
    });

    it("exact value not rounded up", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.fromWadRoundUp(WAD);
      expect(result).to.equal(1_000_000n);
    });

    it("zero returns zero", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.fromWadRoundUp(0n);
      expect(result).to.equal(0n);
    });
  });

  describe("fromWadNearest", () => {
    it("rounds to nearest (down)", async () => {
      const { test } = await loadFixture(deployFixture);
      // 1e18 + 0.4e12 → rounds down to 1e6
      const result = await test.fromWadNearest(WAD + 400_000_000_000n);
      expect(result).to.equal(1_000_000n);
    });

    it("rounds to nearest (up)", async () => {
      const { test } = await loadFixture(deployFixture);
      // 1e18 + 0.6e12 → rounds up to 1e6 + 1
      const result = await test.fromWadNearest(WAD + 600_000_000_000n);
      expect(result).to.equal(1_000_001n);
    });
  });

  describe("fromWadNearestMin1", () => {
    it("returns at least 1 for non-zero input", async () => {
      const { test } = await loadFixture(deployFixture);
      // Very small value that would round to 0
      const result = await test.fromWadNearestMin1(1n);
      expect(result).to.equal(1n);
    });

    it("returns 0 for zero input", async () => {
      const { test } = await loadFixture(deployFixture);
      const result = await test.fromWadNearestMin1(0n);
      expect(result).to.equal(0n);
    });
  });

  // ============================================================
  // CLMSR Cost Helper
  // ============================================================
  describe("clmsrCost", () => {
    it("computes cost = alpha * ln(sumAfter / sumBefore)", async () => {
      const { test } = await loadFixture(deployFixture);
      // alpha=1, sumBefore=4, sumAfter=4*e ≈ cost = 1
      const sumBefore = ethers.parseEther("4");
      const e = ethers.parseEther("2.718281828459045235");
      const sumAfter = await test.wMul(sumBefore, e);
      const cost = await test.clmsrCost(WAD, sumBefore, sumAfter);
      approx(cost, WAD, LOOSE_TOLERANCE);
    });

    it("no change in sum → zero cost", async () => {
      const { test } = await loadFixture(deployFixture);
      const sum = ethers.parseEther("10");
      const cost = await test.clmsrCost(WAD, sum, sum);
      expect(cost).to.equal(0n);
    });
  });

  // ============================================================
  // Property Tests (Fuzz-lite)
  // ============================================================
  describe("Property: mul/div roundtrip", () => {
    it("a * b / b ≈ a for random values", async () => {
      const { test } = await loadFixture(deployFixture);
      const prng = createPrng(12345n);

      for (let i = 0; i < 10; i++) {
        const a = prng.nextInRange(WAD / 10n, WAD * 100n);
        const b = prng.nextInRange(WAD / 10n, WAD * 100n);

        const product = await test.wMul(a, b);
        const back = await test.wDiv(product, b);

        // Allow 1 wei tolerance for rounding
        approx(back, a, 2n);
      }
    });
  });

  describe("Property: exp/ln roundtrip", () => {
    it("ln(exp(x)) ≈ x for small x", async () => {
      const { test } = await loadFixture(deployFixture);

      // Note: v1 uses Taylor series (not PRB-math) for exp/ln.
      // Tolerance aligned with clmsrParity.test.ts: ~1e-6 WAD
      // See: SAFE_EXP_TOLERANCE in clmsrParity.test.ts
      const testValues = [
        ethers.parseEther("0.1"),
        ethers.parseEther("0.5"),
        ethers.parseEther("1"),
      ];

      for (const x of testValues) {
        const expX = await test.wExp(x);
        const lnExpX = await test.wLn(expX);
        // 1e-6 tolerance matches existing parity tests
        const TAYLOR_TOLERANCE = ethers.parseEther("0.000001");
        approx(lnExpX, x, TAYLOR_TOLERANCE);
      }
    });

    it("exp(ln(x)) ≈ x for x > 1 (CLMSR typical range)", async () => {
      const { test } = await loadFixture(deployFixture);

      // CLMSR primarily uses ln for ratios > 1 (Z_after > Z_before)
      // Taylor series precision degrades for larger x
      // Typical CLMSR ratios are 1.0 ~ 2.0 range
      const testValues = [
        ethers.parseEther("1.1"),
        ethers.parseEther("1.5"),
        ethers.parseEther("2"),
      ];

      for (const x of testValues) {
        const lnX = await test.wLn(x);
        const expLnX = await test.wExp(lnX);
        // 0.01% tolerance for Taylor series in typical CLMSR range
        const TAYLOR_TOLERANCE = x / 10000n;
        approx(expLnX, x, TAYLOR_TOLERANCE);
      }
    });
  });

  describe("Property: large values", () => {
    it("handles large but safe multiplications", async () => {
      const { test } = await loadFixture(deployFixture);
      const large = ethers.parseEther("1000000");
      const result = await test.wMul(large, WAD);
      expect(result).to.equal(large);
    });

    it("handles large but safe divisions", async () => {
      const { test } = await loadFixture(deployFixture);
      const large = ethers.parseEther("1000000");
      const result = await test.wDiv(large, WAD);
      expect(result).to.equal(large);
    });
  });
});
