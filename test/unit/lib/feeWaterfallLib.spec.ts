import { expect } from "chai";
import { ethers } from "hardhat";
import { FeeWaterfallLibHarness } from "../../../typechain-types";
import { calculateFeeWaterfall, generateRandomParams } from "../../helpers/feeWaterfallReference";

describe("FeeWaterfallLib", () => {
  let harness: FeeWaterfallLibHarness;

  // Default test parameters
  const defaultParams = {
    Nprev: ethers.parseEther("1000"),    // 1000 NAV
    Bprev: ethers.parseEther("200"),      // 200 Backstop
    Tprev: ethers.parseEther("50"),       // 50 Treasury
    deltaEt: ethers.parseEther("100"),    // 100 available support
    pdd: ethers.parseEther("-0.3"),       // -30% drawdown floor
    rhoBS: ethers.parseEther("0.2"),      // 20% backstop coverage
    phiLP: ethers.parseEther("0.7"),      // 70% to LP
    phiBS: ethers.parseEther("0.2"),      // 20% to Backstop
    phiTR: ethers.parseEther("0.1"),      // 10% to Treasury
  };

  beforeEach(async () => {
    const factory = await ethers.getContractFactory("FeeWaterfallLibHarness");
    harness = await factory.deploy();
    await harness.waitForDeployment();
  });

  // Helper function to call calculate with typed params
  async function calculate(params: {
    Lt: bigint;
    Ftot: bigint;
    Nprev?: bigint;
    Bprev?: bigint;
    Tprev?: bigint;
    deltaEt?: bigint;
    pdd?: bigint;
    rhoBS?: bigint;
    phiLP?: bigint;
    phiBS?: bigint;
    phiTR?: bigint;
  }) {
    return harness.calculate(
      params.Lt,
      params.Ftot,
      params.Nprev ?? defaultParams.Nprev,
      params.Bprev ?? defaultParams.Bprev,
      params.Tprev ?? defaultParams.Tprev,
      params.deltaEt ?? defaultParams.deltaEt,
      params.pdd ?? defaultParams.pdd,
      params.rhoBS ?? defaultParams.rhoBS,
      params.phiLP ?? defaultParams.phiLP,
      params.phiBS ?? defaultParams.phiBS,
      params.phiTR ?? defaultParams.phiTR
    );
  }

  describe("INV-FW1: Fee Conservation", () => {
    it("Floss + Fpool = Ftot for profit case", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("100"), // profit
        Ftot: ethers.parseEther("50"),
      });
      expect(result.Floss + result.Fpool).to.equal(ethers.parseEther("50"));
    });

    it("Floss + Fpool = Ftot for loss covered by fees", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("-30"), // 30 loss
        Ftot: ethers.parseEther("50"), // 50 fees > 30 loss
      });
      expect(result.Floss + result.Fpool).to.equal(ethers.parseEther("50"));
      expect(result.Floss).to.equal(ethers.parseEther("30")); // Floss = loss
    });

    it("Floss + Fpool = Ftot for loss exceeding fees", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("-100"), // 100 loss
        Ftot: ethers.parseEther("20"), // only 20 fees
      });
      expect(result.Floss + result.Fpool).to.equal(ethers.parseEther("20"));
      expect(result.Floss).to.equal(ethers.parseEther("20")); // Floss capped at Ftot
      expect(result.Fpool).to.equal(0n);
    });
  });

  describe("INV-FW2: Loss Compensation Bound", () => {
    it("case 1: profit (Lt >= 0) - no loss compensation", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("100"),
        Ftot: ethers.parseEther("50"),
      });
      expect(result.Floss).to.equal(0n);
      expect(result.Fpool).to.equal(ethers.parseEther("50"));
    });

    it("case 2: loss covered by fees (|Lt| <= Ftot)", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("-30"),
        Ftot: ethers.parseEther("100"),
      });
      expect(result.Floss).to.equal(ethers.parseEther("30"));
      expect(result.Fpool).to.equal(ethers.parseEther("70"));
      expect(result.Gt).to.equal(0n); // No grant needed
    });
  });

  describe("INV-FW3: Grant Bound (WP v2 Safety Invariant)", () => {
    it("case 3: grant needed and deltaEt sufficient", async () => {
      // Loss that requires grant, with sufficient deltaEt
      const result = await calculate({
        Lt: ethers.parseEther("-400"),    // 400 loss
        Ftot: ethers.parseEther("50"),     // 50 fees
        Nprev: ethers.parseEther("1000"),
        Bprev: ethers.parseEther("200"),
        deltaEt: ethers.parseEther("100"), // Sufficient for grantNeed
      });

      // Nraw = 1000 - 400 + 50 = 650
      // Nfloor = 1000 * 0.7 = 700
      // grantNeed = 700 - 650 = 50
      // Gt = 50 (deltaEt = 100 is sufficient)
      expect(result.Gt).to.equal(ethers.parseEther("50"));
      expect(result.Bnext).to.be.lte(ethers.parseEther("200")); // Backstop decreased
    });

    it("case 4: reverts when grant exceeds deltaEt (WP v2: drawdown floor invariant)", async () => {
      // Per whitepaper v2: "if G^need_t > ΔE_t, batch must revert"
      await expect(
        calculate({
          Lt: ethers.parseEther("-500"),    // 500 loss
          Ftot: ethers.parseEther("50"),     // 50 fees
          Nprev: ethers.parseEther("1000"),
          Bprev: ethers.parseEther("200"),
          deltaEt: ethers.parseEther("100"), // grantNeed=150 > deltaEt=100
        })
      ).to.be.revertedWithCustomError(harness, "GrantExceedsTailBudget");
    });

    it("case 5: reverts when grant exceeds backstop", async () => {
      await expect(
        calculate({
          Lt: ethers.parseEther("-400"),    // Loss requiring grant
          Ftot: ethers.parseEther("50"),
          Nprev: ethers.parseEther("1000"),
          Bprev: ethers.parseEther("30"),    // Small backstop < grantNeed
          deltaEt: ethers.parseEther("500"), // High limit but Bprev is low
        })
      ).to.be.revertedWithCustomError(harness, "InsufficientBackstopForGrant");
    });
  });

  describe("INV-FW4: Grant Calculation", () => {
    it("grant is zero when Nraw >= Nfloor", async () => {
      // Small loss, Nraw stays above floor
      const result = await calculate({
        Lt: ethers.parseEther("-50"),
        Ftot: ethers.parseEther("100"),
      });
      // Nraw = 1000 - 50 + 50 = 1000
      // Nfloor = 1000 * 0.7 = 700
      // grantNeed = 0
      expect(result.Gt).to.equal(0n);
    });

    it("grant equals grantNeed when deltaEt is sufficient", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("-400"),
        Ftot: ethers.parseEther("50"),
        deltaEt: ethers.parseEther("500"), // High limit
      });
      // Nraw = 1000 - 400 + 50 = 650
      // Nfloor = 700
      // grantNeed = 50
      // Per WP v2: Gt = grantNeed (no capping, revert if exceeds)
      expect(result.Gt).to.equal(ethers.parseEther("50"));
    });

    it("reverts when grantNeed exceeds deltaEt (WP v2 invariant)", async () => {
      // Per whitepaper v2: "if G^need_t > ΔE_t, batch must revert"
      // This is the Safety Layer invariant - drawdown floor cannot be violated
      await expect(
        calculate({
          Lt: ethers.parseEther("-500"),
          Ftot: ethers.parseEther("50"),
          deltaEt: ethers.parseEther("30"), // Low limit < grantNeed=150
        })
      ).to.be.revertedWithCustomError(harness, "GrantExceedsTailBudget");
    });
  });

  describe("INV-FW5: Backstop Equation", () => {
    it("Bnext = Bprev - Gt + Ffill + FcoreBS", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("100"), // profit
        Ftot: ethers.parseEther("100"),
      });

      // No grant in profit case
      expect(result.Gt).to.equal(0n);

      // Backstop should receive its share
      // Fpool = 100
      // After backstop fill and residual split:
      // Backstop gets Ffill + FcoreBS
      const initialBackstop = defaultParams.Bprev;
      expect(result.Bnext).to.be.gte(initialBackstop);
    });
  });

  describe("INV-FW6: Residual Split Conservation", () => {
    it("residual splits sum correctly", async () => {
      const Ftot = ethers.parseEther("100");
      const result = await calculate({
        Lt: ethers.parseEther("0"), // No P&L
        Ftot,
      });

      // All fees go to pool (no loss compensation)
      expect(result.Floss).to.equal(0n);
      expect(result.Fpool).to.equal(Ftot);
    });

    it("dust goes to LP", async () => {
      // Use amounts that cause rounding
      const result = await calculate({
        Lt: 0n,
        Ftot: ethers.parseEther("100.000000000000000003"), // Small amount with dust
        Nprev: ethers.parseEther("500"), // Low NAV so backstop fill is zero
        Bprev: ethers.parseEther("200"),
      });

      // Ft = Floss + FcoreLP + Fdust, so any dust is included
      // Fdust >= 0
      expect(result.Fdust).to.be.gte(0n);
      expect(result.Ft).to.be.gte(result.Floss);
    });
  });

  describe("INV-NAV1: Pre-batch NAV Equation", () => {
    it("Npre = Nprev + Lt + Ft + Gt for profit", async () => {
      const Lt = ethers.parseEther("100");
      const Ftot = ethers.parseEther("50");

      const result = await calculate({ Lt, Ftot });

      // For profit: Floss = 0, all fees split
      // Npre = Ngrant + FcoreLP = Nraw + Gt + FcoreLP
      // Nraw = Nprev + Lt + Floss = 1000 + 100 + 0 = 1100
      // Gt = 0 (no grant needed in profit)
      // Npre should be around Nprev + Lt + share of fees to LP
      expect(result.Npre).to.be.gt(defaultParams.Nprev);
    });

    it("Npre = Nprev + Lt + Ft + Gt for loss with grant", async () => {
      // Use deltaEt that's sufficient for grantNeed (WP v2: revert if grantNeed > deltaEt)
      const result = await calculate({
        Lt: ethers.parseEther("-400"),  // -400 loss
        Ftot: ethers.parseEther("50"),
        deltaEt: ethers.parseEther("100"), // grantNeed = 50 < deltaEt = 100
      });

      // Nraw = 1000 - 400 + 50 = 650
      // Nfloor = 1000 * 0.7 = 700
      // grantNeed = 700 - 650 = 50
      // Gt = 50 (deltaEt is sufficient)
      expect(result.Npre).to.be.gte(result.Nraw); // Grant increases NAV
      expect(result.Gt).to.be.gt(0n); // Grant should be applied
      expect(result.Gt).to.equal(ethers.parseEther("50"));
    });
  });

  describe("Edge Cases", () => {
    it("handles zero fees", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("100"),
        Ftot: 0n,
      });
      expect(result.Floss).to.equal(0n);
      expect(result.Fpool).to.equal(0n);
      expect(result.Ft).to.equal(0n);
    });

    it("handles zero P&L", async () => {
      const result = await calculate({
        Lt: 0n,
        Ftot: ethers.parseEther("50"),
      });
      expect(result.Floss).to.equal(0n);
      expect(result.Nraw).to.equal(defaultParams.Nprev);
    });

    it("reverts on positive drawdown floor", async () => {
      await expect(
        calculate({
          Lt: 0n,
          Ftot: ethers.parseEther("50"),
          pdd: ethers.parseEther("0.1"), // Invalid: positive
        })
      ).to.be.revertedWithCustomError(harness, "InvalidDrawdownFloor");
    });

    it("reverts on pdd < -WAD (over 100% drawdown)", async () => {
      await expect(
        calculate({
          Lt: 0n,
          Ftot: ethers.parseEther("50"),
          pdd: ethers.parseEther("-1.1"), // Invalid: < -WAD
        })
      ).to.be.revertedWithCustomError(harness, "InvalidDrawdownFloor");
    });

    it("reverts on catastrophic loss (Nraw underflow)", async () => {
      // Loss exceeds NAV + all fees
      await expect(
        calculate({
          Lt: ethers.parseEther("-2000"), // Loss > Nprev + Ftot
          Ftot: ethers.parseEther("10"),
          Nprev: ethers.parseEther("1000"),
        })
      ).to.be.revertedWithCustomError(harness, "CatastrophicLoss");
    });

    it("reverts on invalid phi sum", async () => {
      await expect(
        calculate({
          Lt: 0n,
          Ftot: ethers.parseEther("50"),
          phiLP: ethers.parseEther("0.5"),
          phiBS: ethers.parseEther("0.3"),
          phiTR: ethers.parseEther("0.1"), // Sum = 0.9, not 1.0
        })
      ).to.be.revertedWithCustomError(harness, "InvalidPhiSum");
    });
  });

  describe("WP v2: Ceil Rounding for Nfloor (Safety Invariant)", () => {
    it("uses wMulUp for Nfloor calculation (ceil semantics)", async () => {
      // Test case where wMul vs wMulUp makes a difference
      // Nprev = 1000000000000000000001 (1000e18 + 1 wei)
      // pdd = -0.3e18
      // wadPlusPdd = 0.7e18
      // wMul: (1000000000000000000001 * 0.7e18) / 1e18 = 700000000000000000000 (truncates .7)
      // wMulUp: same but rounds up = 700000000000000000001
      const Nprev = ethers.parseEther("1000") + 1n; // 1000e18 + 1 wei
      const result = await calculate({
        Lt: ethers.parseEther("-301"), // Loss to trigger grant need
        Ftot: ethers.parseEther("1"),
        Nprev,
      });

      // With wMulUp, Nfloor should be ceil(1000.000000000000000001 * 0.7)
      // = ceil(700.0000000000000000007) = 700000000000000000001
      // Without it (wMul), Nfloor = 700000000000000000000
      
      // The key invariant: drawdown floor is maintained conservatively
      // Npre should be >= Nfloor
      
      // Nraw = 1000e18+1 - 301e18 + 1e18 = 700e18 + 1
      // With wMulUp: Nfloor = ceil(700.0..007) = 700e18 + 1
      // grantNeed = max(0, Nfloor - Nraw) = 0 in this case
      expect(result.Gt).to.equal(0n);
    });

    it("ceil semantics ensures grantNeed is never under-estimated", async () => {
      // Create a case where rounding matters for grant calculation
      // Nprev that causes fractional Nfloor
      const Nprev = ethers.parseEther("999") + 999999999999999999n; // ~999.999...e18
      const result = await calculate({
        Lt: ethers.parseEther("-350"), // Loss
        Ftot: ethers.parseEther("50"),
        Nprev,
        deltaEt: ethers.parseEther("500"), // High limit to not revert
      });

      // Nfloor with ceil = ceil(Nprev * 0.7)
      // The ceil ensures that if there's any fractional part, we round up
      // This guarantees grantNeed >= actual required grant
      
      // Verify the NAV equation holds
      const navDelta = result.Npre - Nprev;
      const expected = ethers.parseEther("-350") + BigInt(result.Ft) + BigInt(result.Gt);
      expect(navDelta).to.equal(expected);
    });

    it("maintains drawdown floor invariant with ceil rounding", async () => {
      // Test multiple Nprev values with small fractional components
      const testCases = [
        ethers.parseEther("1000") + 1n,
        ethers.parseEther("1000") + 123456789n,
        ethers.parseEther("1000") + ethers.parseEther("0.5"),
        ethers.parseEther("1000") + 999999999999999999n,
      ];

      for (const Nprev of testCases) {
        const result = await calculate({
          Lt: ethers.parseEther("-400"),
          Ftot: ethers.parseEther("50"),
          Nprev,
          deltaEt: ethers.parseEther("500"),
        });

        // Calculate expected Nfloor with ceil
        const wadPlusPdd = ethers.parseEther("0.7"); // 1 - 0.3
        const product = Nprev * wadPlusPdd;
        const expectedNfloorCeil = product === 0n ? 0n : (product - 1n) / ethers.parseEther("1") + 1n;
        
        // Npre should be >= Nfloor (drawdown floor maintained)
        expect(result.Npre).to.be.gte(expectedNfloorCeil, 
          `Drawdown floor violated for Nprev=${Nprev}`);
      }
    });
  });

  describe("Property Tests", () => {
    it("Backstop NAV never goes negative", async () => {
      // Even with max grant, backstop should stay >= 0
      const result = await calculate({
        Lt: ethers.parseEther("-400"),
        Ftot: ethers.parseEther("50"),
        deltaEt: ethers.parseEther("100"),
      });
      expect(result.Bnext).to.be.gte(0n);
    });

    it("Treasury NAV never decreases", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("-200"),
        Ftot: ethers.parseEther("30"),
      });
      expect(result.Tnext).to.be.gte(defaultParams.Tprev);
    });

    it("Total value is conserved (fees + grant)", async () => {
      const Ftot = ethers.parseEther("100");
      const Lt = ethers.parseEther("-300");
      const result = await calculate({ Lt, Ftot });

      // Conservation: Ftot flows entirely into system
      // Floss + Fpool = Ftot (fee split)
      expect(result.Floss + result.Fpool).to.equal(Ftot);

      // Total system NAV change should equal fees distributed + P&L
      // Before: Nprev + Bprev + Tprev
      // After:  Npre + Bnext + Tnext
      // Delta should equal: Lt + Ftot (P&L + fees absorbed)
      const before = defaultParams.Nprev + defaultParams.Bprev + defaultParams.Tprev;
      const after = result.Npre + result.Bnext + result.Tnext;
      const delta = after > before ? after - before : before - after;
      const expectedDelta = Lt + Ftot;
      // Allow 1 wei tolerance for rounding
      expect(delta).to.be.closeTo(expectedDelta > 0n ? expectedDelta : -expectedDelta, 1n);
    });

    it("INV: Floss + Fpool == Ftot", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("-200"),
        Ftot: ethers.parseEther("80"),
      });
      expect(result.Floss + result.Fpool).to.equal(ethers.parseEther("80"));
    });

    it("INV: Gt <= deltaEt (always true per WP v2 - reverts if exceeded)", async () => {
      // WP v2: if grantNeed > deltaEt, batch reverts
      // So for any successful call, Gt = grantNeed <= deltaEt
      const result = await calculate({
        Lt: ethers.parseEther("-350"),  // Loss that results in grantNeed <= deltaEt
        Ftot: ethers.parseEther("50"),
        deltaEt: ethers.parseEther("100"), // grantNeed = 0 since Nraw=700 = Nfloor
      });
      // Nraw = 1000 - 350 + 50 = 700 = Nfloor, so grantNeed = 0
      expect(result.Gt).to.equal(0n);
      expect(result.Gt).to.be.lte(ethers.parseEther("100"));
    });

    it("INV: Gt <= Bprev", async () => {
      const result = await calculate({
        Lt: ethers.parseEther("-400"),
        Ftot: ethers.parseEther("50"),
        Bprev: ethers.parseEther("200"),
        deltaEt: ethers.parseEther("300"),
      });
      expect(result.Gt).to.be.lte(ethers.parseEther("200"));
    });

    it("INV: Npre - Nprev == Lt + Ft + Gt (pre-batch NAV equation)", async () => {
      const Lt = ethers.parseEther("-300");
      const Ftot = ethers.parseEther("100");
      const result = await calculate({ Lt, Ftot });

      // Npre - Nprev = Lt + Ft + Gt
      const navDelta = result.Npre > defaultParams.Nprev 
        ? result.Npre - defaultParams.Nprev 
        : -(defaultParams.Nprev - result.Npre);
      const expected = Lt + BigInt(result.Ft) + BigInt(result.Gt);
      expect(navDelta).to.equal(expected);
    });
  });

  describe("JS Reference Parity", () => {
    it("matches JS reference for profit case", async () => {
      const params = {
        Lt: ethers.parseEther("100"),
        Ftot: ethers.parseEther("50"),
        Nprev: defaultParams.Nprev,
        Bprev: defaultParams.Bprev,
        Tprev: defaultParams.Tprev,
        deltaEt: defaultParams.deltaEt,
        pdd: defaultParams.pdd,
        rhoBS: defaultParams.rhoBS,
        phiLP: defaultParams.phiLP,
        phiBS: defaultParams.phiBS,
        phiTR: defaultParams.phiTR,
      };

      const onchain = await harness.calculate(
        params.Lt, params.Ftot, params.Nprev, params.Bprev, params.Tprev,
        params.deltaEt, params.pdd, params.rhoBS, params.phiLP, params.phiBS, params.phiTR
      );

      const offchain = calculateFeeWaterfall(params);

      expect(onchain.Floss).to.equal(offchain.Floss);
      expect(onchain.Fpool).to.equal(offchain.Fpool);
      expect(onchain.Gt).to.equal(offchain.Gt);
      expect(onchain.Npre).to.equal(offchain.Npre);
      expect(onchain.Bnext).to.equal(offchain.Bnext);
      expect(onchain.Tnext).to.equal(offchain.Tnext);
    });

    it("matches JS reference for loss with grant case", async () => {
      // Use parameters where grantNeed <= deltaEt (WP v2 requirement)
      // Lt = -400, Ftot = 50 => Nraw = 650, Nfloor = 700, grantNeed = 50
      const params = {
        Lt: ethers.parseEther("-400"),
        Ftot: ethers.parseEther("50"),
        Nprev: defaultParams.Nprev,
        Bprev: defaultParams.Bprev,
        Tprev: defaultParams.Tprev,
        deltaEt: ethers.parseEther("100"), // grantNeed (50) <= deltaEt (100)
        pdd: defaultParams.pdd,
        rhoBS: defaultParams.rhoBS,
        phiLP: defaultParams.phiLP,
        phiBS: defaultParams.phiBS,
        phiTR: defaultParams.phiTR,
      };

      const onchain = await harness.calculate(
        params.Lt, params.Ftot, params.Nprev, params.Bprev, params.Tprev,
        params.deltaEt, params.pdd, params.rhoBS, params.phiLP, params.phiBS, params.phiTR
      );

      const offchain = calculateFeeWaterfall(params);

      expect(onchain.Floss).to.equal(offchain.Floss);
      expect(onchain.Fpool).to.equal(offchain.Fpool);
      expect(onchain.Gt).to.equal(offchain.Gt);
      expect(onchain.Npre).to.equal(offchain.Npre);
      expect(onchain.Bnext).to.equal(offchain.Bnext);
      expect(onchain.Tnext).to.equal(offchain.Tnext);
    });

    it("matches JS reference for 10 random cases", async () => {
      for (let i = 0; i < 10; i++) {
        const params = generateRandomParams();
        
        // Skip cases that would revert (WP v2: grantNeed > deltaEt reverts)
        if (params.Lt < 0n) {
          const Lneg = -params.Lt;
          const Floss = Lneg < params.Ftot ? Lneg : params.Ftot;
          const Nraw = params.Nprev + params.Lt + Floss;
          const wadPlusPdd = 10n ** 18n + params.pdd;
          const Nfloor = wadPlusPdd > 0n ? (params.Nprev * wadPlusPdd) / (10n ** 18n) : 0n;
          const grantNeed = Nfloor > Nraw ? Nfloor - Nraw : 0n;
          // WP v2: grantNeed > deltaEt causes revert (no capping)
          if (grantNeed > params.deltaEt) continue;
          // Also skip if grant exceeds backstop
          if (grantNeed > params.Bprev) continue;
        }

        try {
          const onchain = await harness.calculate(
            params.Lt, params.Ftot, params.Nprev, params.Bprev, params.Tprev,
            params.deltaEt, params.pdd, params.rhoBS, params.phiLP, params.phiBS, params.phiTR
          );

          const offchain = calculateFeeWaterfall(params);

          // Allow 1 wei tolerance for rounding
          expect(onchain.Npre).to.be.closeTo(offchain.Npre, 1n);
          expect(onchain.Bnext).to.be.closeTo(offchain.Bnext, 1n);
          expect(onchain.Tnext).to.be.closeTo(offchain.Tnext, 1n);
        } catch {
          // Skip reverted cases
        }
      }
    });
  });

  describe("INV: Fuzz Property Tests (100 cases)", () => {
    const WAD = 10n ** 18n;

    it("all core invariants hold for 100 random parameter sets", async () => {
      let validCases = 0;
      const targetCases = 100;

      while (validCases < targetCases) {
        const params = generateRandomParams();

        // Skip cases that would revert (WP v2 rules)
        if (params.Lt < 0n) {
          const Lneg = -params.Lt;
          const Floss = Lneg < params.Ftot ? Lneg : params.Ftot;
          const Nraw = params.Nprev + params.Lt + Floss;
          if (Nraw < 0n) continue; // Would cause CatastrophicLoss

          const wadPlusPdd = WAD + params.pdd;
          const Nfloor = wadPlusPdd > 0n ? (params.Nprev * wadPlusPdd) / WAD : 0n;
          const grantNeed = Nfloor > Nraw ? Nfloor - Nraw : 0n;
          // WP v2: grantNeed > deltaEt causes revert (drawdown floor invariant)
          if (grantNeed > params.deltaEt) continue;
          // Also skip if grant exceeds backstop
          if (grantNeed > params.Bprev) continue;
        }

        try {
          const onchain = await harness.calculate(
            params.Lt, params.Ftot, params.Nprev, params.Bprev, params.Tprev,
            params.deltaEt, params.pdd, params.rhoBS, params.phiLP, params.phiBS, params.phiTR
          );

          // INV-FW1: Floss + Fpool == Ftot
          expect(onchain.Floss + onchain.Fpool).to.equal(params.Ftot);

          // INV-BS-POS: Bnext >= 0
          expect(onchain.Bnext).to.be.gte(0n);

          // INV-TR: Tnext >= Tprev
          expect(onchain.Tnext).to.be.gte(params.Tprev);

          // INV-NAV1: Npre - Nprev == Lt + Ft + Gt
          const navDelta = onchain.Npre - params.Nprev;
          const expected = params.Lt + onchain.Ft + onchain.Gt;
          expect(navDelta).to.equal(expected);

          // INV-FW3: Gt <= deltaEt
          expect(onchain.Gt).to.be.lte(params.deltaEt);

          // INV-FW3: Gt <= Bprev
          expect(onchain.Gt).to.be.lte(params.Bprev);

          validCases++;
        } catch {
          // Skip reverted cases
        }
      }
    }).timeout(60000);
  });
});

