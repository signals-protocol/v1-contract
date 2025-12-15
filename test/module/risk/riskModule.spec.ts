import { expect } from "chai";
import { ethers } from "hardhat";
import { 
  SignalsCoreHarness, 
  MockPaymentToken, 
  MockSignalsPosition, 
  RiskModule
} from "../../../typechain-types";

/**
 * Phase 7: RiskModule Tests (TDD)
 * 
 * Test Plan (per whitepaper v2):
 * 1. ΔEₜ Calculation (Sec 4.1)
 *    - Uniform prior: ΔEₜ = 0
 *    - Concentrated prior: ΔEₜ > 0
 * 
 * 2. α Safety Bounds (Sec 4.3-4.5)
 *    - αbase,t = λ * E_t / ln(n)
 *    - αlimit,t = max{0, αbase,t * (1 - k * DD_t)}
 * 
 * 3. Prior Admissibility (Sec 4.1)
 *    - ΔEₜ ≤ B^eff_{t-1} or revert
 * 
 * 4. Trade α Enforcement (Sec 4.5)
 *    - Market α ≤ αlimit or revert on create/increase
 *    - close/decrease always allowed
 */

const WAD = ethers.parseEther("1");
const LAMBDA = ethers.parseEther("0.3"); // 30% max drawdown (pdd = -λ)
const K_DD = ethers.parseEther("1");     // Drawdown sensitivity factor

describe("RiskModule", () => {
  let core: SignalsCoreHarness;
  let riskModule: RiskModule;
  let payment: MockPaymentToken;
  let position: MockSignalsPosition;
  let owner: Awaited<ReturnType<typeof ethers.getSigners>>[0];

  async function deployFixture() {
    const [_owner] = await ethers.getSigners();
    owner = _owner;

    payment = await (await ethers.getContractFactory("MockPaymentToken")).deploy();
    position = await (await ethers.getContractFactory("MockSignalsPosition")).deploy();
    const lazyLib = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();

    // Deploy RiskModule
    riskModule = await (await ethers.getContractFactory("RiskModule")).deploy();

    // Deploy SignalsCoreHarness with modules
    const coreImpl = await (
      await ethers.getContractFactory("SignalsCoreHarness", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();

    const initData = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      120, // settlementSubmitWindow
      60,  // settlementFinalizeDeadline
    ]);

    const proxy = await (await ethers.getContractFactory("TestERC1967Proxy")).deploy(
      coreImpl.target,
      initData
    );
    core = (await ethers.getContractAt("SignalsCoreHarness", proxy.target)) as SignalsCoreHarness;

    // Deploy other modules
    const lifecycleImpl = await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();
    const tradeImpl = await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy();
    const lpVaultImpl = await (
      await ethers.getContractFactory("LPVaultModule")
    ).deploy();
    const oracleImpl = await (
      await ethers.getContractFactory("OracleModule")
    ).deploy();

    // setModules order: (tradeModule, lifecycleModule, riskModule, vaultModule, oracleModule)
    await core.setModules(
      tradeImpl.target,
      lifecycleImpl.target,
      riskModule.target,
      lpVaultImpl.target,
      oracleImpl.target
    );

    // Configure vault
    await core.setMinSeedAmount(ethers.parseUnits("100", 6));
    await core.setFeeWaterfallConfig(
      ethers.parseEther("-0.3"), // pdd = -30%
      ethers.parseEther("0.2"),  // rhoBS = 20%
      ethers.parseEther("0.7"),  // phiLP = 70%
      ethers.parseEther("0.2"),  // phiBS = 20%
      ethers.parseEther("0.1")   // phiTR = 10%
    );

    // Seed vault for testing
    await payment.mint(owner.address, ethers.parseUnits("100000", 6));
    await payment.approve(core.target, ethers.MaxUint256);
    await core.seedVault(ethers.parseUnits("10000", 6));

    // Setup Backstop and Treasury NAV for testing
    await core.setCapitalStack(
      ethers.parseEther("2000"), // backstopNav = 2000
      ethers.parseEther("500")  // treasuryNav = 500
    );
  }

  beforeEach(async () => {
    await deployFixture();
  });

  // ============================================================
  // 7-0.5: ΔEₜ (Tail Budget) Calculation
  // ============================================================
  describe("7-0.5: ΔEₜ (Tail Budget) Calculation", () => {
    it("returns zero for uniform prior (no tail risk)", async () => {
      // For uniform prior q₀ = 0, E_ent = α ln n, so ΔEₜ = 0
      const numBins = 100n;
      const alpha = ethers.parseEther("1000"); // α
      
      const deltaEt = await riskModule.calculateDeltaEt(
        alpha,
        numBins,
        0n // uniform prior weight (no concentration)
      );
      
      expect(deltaEt).to.equal(0n);
    });

    it("returns positive ΔEₜ for concentrated prior", async () => {
      // Concentrated prior: min_j q₀,j < 0 → E_ent > α ln n → ΔEₜ > 0
      const numBins = 100n;
      const alpha = ethers.parseEther("1000");
      const priorConcentration = ethers.parseEther("0.5"); // Concentrated prior
      
      const deltaEt = await riskModule.calculateDeltaEt(
        alpha,
        numBins,
        priorConcentration
      );
      
      expect(deltaEt).to.be.gt(0n);
    });

    it("ΔEₜ scales with prior concentration", async () => {
      const numBins = 100n;
      const alpha = ethers.parseEther("1000");
      
      const deltaEt1 = await riskModule.calculateDeltaEt(alpha, numBins, ethers.parseEther("0.1"));
      const deltaEt2 = await riskModule.calculateDeltaEt(alpha, numBins, ethers.parseEther("0.5"));
      
      // More concentrated prior → higher tail risk → higher ΔEₜ
      expect(deltaEt2).to.be.gt(deltaEt1);
    });
  });

  // ============================================================
  // 7-1: α Safety Bounds
  // ============================================================
  describe("7-1: α Safety Bounds (αbase / αlimit)", () => {
    it("calculates αbase = λ * E_t / ln(n)", async () => {
      const Et = ethers.parseEther("10000"); // E_t = NAV_{t-1}
      const numBins = 100n;
      
      const alphaBase = await riskModule.calculateAlphaBase(Et, numBins, LAMBDA);
      
      // αbase = λ * E_t / ln(n) = 0.3 * 10000 / ln(100) = 3000 / 4.605 ≈ 651.5
      // ln(100) ≈ 4.605 * WAD
      const lnN = await riskModule.lnWad(numBins);
      const expectedAlphaBase = (LAMBDA * Et) / lnN;
      
      expect(alphaBase).to.be.closeTo(expectedAlphaBase, ethers.parseEther("1"));
    });

    it("αlimit = αbase when drawdown is zero", async () => {
      const Et = ethers.parseEther("10000");
      const numBins = 100n;
      const drawdown = 0n; // No drawdown
      
      const alphaBase = await riskModule.calculateAlphaBase(Et, numBins, LAMBDA);
      const alphaLimit = await riskModule.calculateAlphaLimit(alphaBase, drawdown, K_DD);
      
      expect(alphaLimit).to.equal(alphaBase);
    });

    it("αlimit decreases with drawdown", async () => {
      const Et = ethers.parseEther("10000");
      const numBins = 100n;
      const drawdown = ethers.parseEther("0.2"); // 20% drawdown
      
      const alphaBase = await riskModule.calculateAlphaBase(Et, numBins, LAMBDA);
      const alphaLimit = await riskModule.calculateAlphaLimit(alphaBase, drawdown, K_DD);
      
      // αlimit = αbase * (1 - k * DD) = αbase * 0.8
      const expectedLimit = (alphaBase * (WAD - drawdown)) / WAD;
      
      expect(alphaLimit).to.equal(expectedLimit);
    });

    it("αlimit = 0 when drawdown reaches 100% (extreme)", async () => {
      const Et = ethers.parseEther("10000");
      const numBins = 100n;
      const drawdown = WAD; // 100% drawdown
      
      const alphaBase = await riskModule.calculateAlphaBase(Et, numBins, LAMBDA);
      const alphaLimit = await riskModule.calculateAlphaLimit(alphaBase, drawdown, K_DD);
      
      expect(alphaLimit).to.equal(0n);
    });

    it("αlimit never goes negative (max with 0)", async () => {
      const Et = ethers.parseEther("10000");
      const numBins = 100n;
      const drawdown = ethers.parseEther("1.5"); // 150% drawdown (impossible but test edge)
      
      const alphaBase = await riskModule.calculateAlphaBase(Et, numBins, LAMBDA);
      const alphaLimit = await riskModule.calculateAlphaLimit(alphaBase, drawdown, K_DD);
      
      expect(alphaLimit).to.equal(0n); // max(0, negative) = 0
    });
  });

  // ============================================================
  // Prior Admissibility
  // ============================================================
  describe("Prior Admissibility (ΔEₜ ≤ B^eff)", () => {
    it("accepts prior when ΔEₜ ≤ B^eff", async () => {
      const deltaEt = ethers.parseEther("100");
      const effectiveBackstop = ethers.parseEther("200");
      
      // Should not revert
      await expect(
        riskModule.checkPriorAdmissibility(deltaEt, effectiveBackstop)
      ).to.not.be.reverted;
    });

    it("rejects prior when ΔEₜ > B^eff", async () => {
      const deltaEt = ethers.parseEther("300");
      const effectiveBackstop = ethers.parseEther("200");
      
      await expect(
        riskModule.checkPriorAdmissibility(deltaEt, effectiveBackstop)
      ).to.be.revertedWithCustomError(riskModule, "PriorNotAdmissible");
    });
  });

  // ============================================================
  // 7-2: Trade α Enforcement Integration
  // ============================================================
  describe("7-2: Trade α Enforcement", () => {
    it("reverts market creation when α > αlimit", async () => {
      // Setup: Create high drawdown state to reduce αlimit
      // Then try to create market with α > αlimit
      
      // This requires integration with core, tested via core.createMarket
      // Skipping direct RiskModule test, will be tested via integration
    });

    it("reverts position increase when market α > αlimit", async () => {
      // Similar to above - integration test
    });

    it("allows position decrease even when α > αlimit", async () => {
      // Decrease/close should always be allowed (reducing exposure)
    });
  });

  // ============================================================
  // 7-4: α Enforcement Test Cases
  // ============================================================
  describe("7-4: α Enforcement Scenarios", () => {
    describe("Happy path (α within limit)", () => {
      it("allows market creation when α ≤ αlimit", async () => {
        // Will be tested via integration
      });

      it("allows trading when market α ≤ αlimit", async () => {
        // Will be tested via integration
      });
    });

    describe("Drawdown triggers α limit reduction", () => {
      it("reduces αlimit proportionally to drawdown", async () => {
        const alphaBase = ethers.parseEther("1000");
        
        const limit0 = await riskModule.calculateAlphaLimit(alphaBase, 0n, K_DD);
        const limit10 = await riskModule.calculateAlphaLimit(alphaBase, ethers.parseEther("0.1"), K_DD);
        const limit50 = await riskModule.calculateAlphaLimit(alphaBase, ethers.parseEther("0.5"), K_DD);
        
        expect(limit0).to.equal(alphaBase);
        expect(limit10).to.equal((alphaBase * 9n) / 10n);
        expect(limit50).to.equal((alphaBase * 5n) / 10n);
      });
    });

    describe("Recovery (α limit increases)", () => {
      it("αlimit increases as drawdown recovers", async () => {
        const alphaBase = ethers.parseEther("1000");
        
        // Start at 50% drawdown
        const limitDrawdown = await riskModule.calculateAlphaLimit(
          alphaBase, 
          ethers.parseEther("0.5"), 
          K_DD
        );
        
        // Recover to 20% drawdown
        const limitRecovered = await riskModule.calculateAlphaLimit(
          alphaBase, 
          ethers.parseEther("0.2"), 
          K_DD
        );
        
        expect(limitRecovered).to.be.gt(limitDrawdown);
      });
    });

    describe("Extreme drawdown (DD → 1, αlimit = 0)", () => {
      it("αlimit = 0 prevents all new market creation", async () => {
        const alphaBase = ethers.parseEther("1000");
        const extremeDrawdown = WAD; // 100%
        
        const alphaLimit = await riskModule.calculateAlphaLimit(
          alphaBase, 
          extremeDrawdown, 
          K_DD
        );
        
        expect(alphaLimit).to.equal(0n);
        // Any α > 0 will exceed limit → market creation should fail
      });
    });
  });
});

