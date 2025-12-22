import { expect } from 'chai';
import { ethers } from 'hardhat';
import { RiskModule } from '../../../typechain-types';

/**
 * RiskMath Unit Tests
 * Tests core risk calculations per whitepaper sections 4.1-4.5
 */
describe('RiskMath', () => {
  // We test RiskMath through RiskModule since library functions are internal
  let riskModule: RiskModule;

  beforeEach(async () => {
    // Deploy RiskModule directly for pure function testing
    const RiskModule = await ethers.getContractFactory('RiskModule');
    riskModule = await RiskModule.deploy() as RiskModule;
  });

  describe('calculateAlphaBase', () => {
    it('returns correct αbase = λ * E_t / ln(n)', async () => {
      // E_t = 1000 WAD, λ = 0.3, n = 10
      // ln(10) ≈ 2.302585
      // αbase = 0.3 * 1000 / 2.302585 ≈ 130.28
      const Et = ethers.parseEther('1000');
      const lambda = ethers.parseEther('0.3');
      const numBins = 10;
      
      const alphaBase = await riskModule.calculateAlphaBase(Et, numBins, lambda);
      
      // Should be approximately 130.28 WAD
      expect(alphaBase).to.be.gt(ethers.parseEther('130'));
      expect(alphaBase).to.be.lt(ethers.parseEther('131'));
    });

    it('reverts with numBins <= 1', async () => {
      const Et = ethers.parseEther('1000');
      const lambda = ethers.parseEther('0.3');
      
      await expect(riskModule.calculateAlphaBase(Et, 1, lambda))
        .to.be.revertedWithCustomError(riskModule, 'InvalidNumBins');
    });
  });

  describe('calculateAlphaLimit', () => {
    it('returns αbase when drawdown = 0', async () => {
      const alphaBase = ethers.parseEther('100');
      const drawdown = 0n;
      const k = ethers.parseEther('1');
      
      const alphaLimit = await riskModule.calculateAlphaLimit(alphaBase, drawdown, k);
      
      expect(alphaLimit).to.equal(alphaBase);
    });

    it('returns reduced αlimit with 20% drawdown', async () => {
      // αlimit = αbase * (1 - k * DD) = 100 * (1 - 1 * 0.2) = 80
      const alphaBase = ethers.parseEther('100');
      const drawdown = ethers.parseEther('0.2'); // 20%
      const k = ethers.parseEther('1');
      
      const alphaLimit = await riskModule.calculateAlphaLimit(alphaBase, drawdown, k);
      
      expect(alphaLimit).to.equal(ethers.parseEther('80'));
    });

    it('returns 0 when k * DD >= 1', async () => {
      const alphaBase = ethers.parseEther('100');
      const drawdown = ethers.parseEther('1'); // 100%
      const k = ethers.parseEther('1');
      
      const alphaLimit = await riskModule.calculateAlphaLimit(alphaBase, drawdown, k);
      
      expect(alphaLimit).to.equal(0n);
    });

    it('handles k > 1 correctly', async () => {
      // k = 2, DD = 0.5 → k * DD = 1 → αlimit = 0
      const alphaBase = ethers.parseEther('100');
      const drawdown = ethers.parseEther('0.5');
      const k = ethers.parseEther('2');
      
      const alphaLimit = await riskModule.calculateAlphaLimit(alphaBase, drawdown, k);
      
      expect(alphaLimit).to.equal(0n);
    });
  });

  describe('calculateDeltaEt', () => {
    it('returns 0 for uniform prior (concentration = 0)', async () => {
      const alpha = ethers.parseEther('100');
      const numBins = 10;
      const priorConcentration = 0n; // uniform
      
      const deltaEt = await riskModule.calculateDeltaEt(alpha, numBins, priorConcentration);
      
      expect(deltaEt).to.equal(0n);
    });

    it('returns positive value for concentrated prior', async () => {
      const alpha = ethers.parseEther('100');
      const numBins = 10;
      const priorConcentration = ethers.parseEther('0.5'); // 50% concentration
      
      const deltaEt = await riskModule.calculateDeltaEt(alpha, numBins, priorConcentration);
      
      expect(deltaEt).to.be.gt(0n);
    });
  });

  describe('lnWad', () => {
    it('returns correct ln(2) ≈ 0.693', async () => {
      const ln2 = await riskModule.lnWad(2);
      
      // ln(2) ≈ 0.693147
      expect(ln2).to.be.gt(ethers.parseEther('0.693'));
      expect(ln2).to.be.lt(ethers.parseEther('0.694'));
    });

    it('returns correct ln(10) ≈ 2.302', async () => {
      const ln10 = await riskModule.lnWad(10);
      
      // ln(10) ≈ 2.302585
      expect(ln10).to.be.gt(ethers.parseEther('2.302'));
      expect(ln10).to.be.lt(ethers.parseEther('2.303'));
    });

    it('returns correct ln(100) ≈ 4.605', async () => {
      const ln100 = await riskModule.lnWad(100);
      
      // ln(100) ≈ 4.605
      expect(ln100).to.be.gt(ethers.parseEther('4.605'));
      expect(ln100).to.be.lt(ethers.parseEther('4.606'));
    });
  });

  // Note: calculateDrawdown and enforceAlphaLimit are internal library functions
  // not directly exposed on RiskModule. They are tested via integration tests
  // in test/integration/risk/alphaEnforcement.spec.ts
});

