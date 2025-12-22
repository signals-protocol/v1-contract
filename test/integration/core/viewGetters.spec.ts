import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";
import { SignalsCoreHarness } from "../../../typechain-types";

/**
 * Core View Getters Tests
 *
 * Tests for FE-facing view functions.
 */
describe("Core View Getters", () => {
  let owner: Signer;
  let core: SignalsCoreHarness;

  beforeEach(async () => {
    [owner] = await ethers.getSigners();

    // Deploy mock payment token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const paymentToken = await MockERC20.deploy("USDC", "USDC", 6);

    // Deploy position with proxy
    const positionImplFactory = await ethers.getContractFactory(
      "SignalsPosition"
    );
    const positionImpl = await positionImplFactory.deploy();
    const positionInit = positionImplFactory.interface.encodeFunctionData(
      "initialize",
      [await owner.getAddress()]
    );
    const positionProxy = await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(await positionImpl.getAddress(), positionInit);
    const position = await ethers.getContractAt(
      "SignalsPosition",
      await positionProxy.getAddress()
    );

    // Deploy LazyMulSegmentTree library
    const LazyMulSegmentTree = await ethers.getContractFactory(
      "LazyMulSegmentTree"
    );
    const lazyLib = await LazyMulSegmentTree.deploy();

    // Deploy core harness with library linking
    const SignalsCoreHarnessFactory = await ethers.getContractFactory(
      "SignalsCoreHarness",
      {
        libraries: { LazyMulSegmentTree: await lazyLib.getAddress() },
      }
    );
    const coreImpl = await SignalsCoreHarnessFactory.deploy();

    // Deploy proxy
    const initData = SignalsCoreHarnessFactory.interface.encodeFunctionData(
      "initialize",
      [
        await paymentToken.getAddress(),
        await position.getAddress(),
        3600,
        86400,
      ]
    );
    const proxy = await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(await coreImpl.getAddress(), initData);

    core = SignalsCoreHarnessFactory.attach(
      await proxy.getAddress()
    ) as SignalsCoreHarness;

    // Connect position to core
    await position.setCore(await core.getAddress());

    // Deploy and set modules with library linking
    const RiskModule = await ethers.getContractFactory("RiskModule");
    const riskModule = await RiskModule.deploy();

    const TradeModule = await ethers.getContractFactory("TradeModule", {
      libraries: { LazyMulSegmentTree: await lazyLib.getAddress() },
    });
    const tradeModule = await TradeModule.deploy();

    const MarketLifecycleModule = await ethers.getContractFactory(
      "MarketLifecycleModule",
      {
        libraries: { LazyMulSegmentTree: await lazyLib.getAddress() },
      }
    );
    const lifecycleModule = await MarketLifecycleModule.deploy();

    const LPVaultModule = await ethers.getContractFactory("LPVaultModule");
    const vaultModule = await LPVaultModule.deploy();

    // Use OracleModuleHarness to allow Hardhat local signers for Redstone verification
    const OracleModule = await ethers.getContractFactory("OracleModuleHarness");
    const oracleModule = await OracleModule.deploy();

    await core.setModules(
      await tradeModule.getAddress(),
      await lifecycleModule.getAddress(),
      await riskModule.getAddress(),
      await vaultModule.getAddress(),
      await oracleModule.getAddress()
    );
  });

  describe("Vault view getters", () => {
    beforeEach(async () => {
      await core.harnessSetLpVault(
        ethers.parseEther("1000"), // nav
        ethers.parseEther("500"), // shares
        ethers.parseEther("2"), // price
        ethers.parseEther("2.5"), // pricePeak
        true
      );
    });

    it("getVaultNav returns correct NAV", async () => {
      expect(await core.getVaultNav()).to.equal(ethers.parseEther("1000"));
    });

    it("getVaultShares returns correct total shares", async () => {
      expect(await core.getVaultShares()).to.equal(ethers.parseEther("500"));
    });

    it("getVaultPrice returns correct price", async () => {
      expect(await core.getVaultPrice()).to.equal(ethers.parseEther("2"));
    });

    it("getVaultPricePeak returns correct peak", async () => {
      expect(await core.getVaultPricePeak()).to.equal(ethers.parseEther("2.5"));
    });

    it("isVaultSeeded returns correct status", async () => {
      expect(await core.isVaultSeeded()).to.equal(true);
    });

    it("getVaultDrawdown calculates correctly", async () => {
      // DD = 1 - price/peak = 1 - 2/2.5 = 0.2 (20%)
      const drawdown = await core.getVaultDrawdown();
      expect(drawdown).to.equal(ethers.parseEther("0.2"));
    });

    it("getVaultDrawdown returns 0 when price >= pricePeak", async () => {
      await core.harnessSetLpVault(
        ethers.parseEther("1000"),
        ethers.parseEther("500"),
        ethers.parseEther("3"), // price > pricePeak
        ethers.parseEther("2.5"),
        true
      );
      const drawdown = await core.getVaultDrawdown();
      expect(drawdown).to.equal(0);
    });

    it("isVaultSeeded returns false when not seeded", async () => {
      await core.harnessSetLpVault(0, 0, 0, 0, false);
      expect(await core.isVaultSeeded()).to.equal(false);
    });
  });

  describe("Risk config getter", () => {
    beforeEach(async () => {
      await core.setRiskConfig(
        ethers.parseEther("0.3"), // lambda
        ethers.parseEther("1.5"), // kDrawdown
        true // enforceAlpha
      );
    });

    it("getRiskConfig returns all parameters", async () => {
      const [lambda, kDrawdown, enforceAlpha] = await core.getRiskConfig();

      expect(lambda).to.equal(ethers.parseEther("0.3"));
      expect(kDrawdown).to.equal(ethers.parseEther("1.5"));
      expect(enforceAlpha).to.equal(true);
    });
  });

  describe("Fee waterfall config getter", () => {
    beforeEach(async () => {
      await core.setRiskConfig(
        ethers.parseEther("0.3"),
        ethers.parseEther("1"),
        true
      );

      await core.setFeeWaterfallConfig(
        ethers.parseEther("0.1"), // rhoBS
        ethers.parseEther("0.7"), // phiLP
        ethers.parseEther("0.2"), // phiBS
        ethers.parseEther("0.1") // phiTR
      );
    });

    it("getFeeWaterfallConfig returns all parameters", async () => {
      const [rhoBS, pdd, phiLP, phiBS, phiTR] =
        await core.getFeeWaterfallConfig();

      expect(rhoBS).to.equal(ethers.parseEther("0.1"));
      // pdd = -lambda = -0.3
      expect(pdd).to.equal(-ethers.parseEther("0.3"));
      expect(phiLP).to.equal(ethers.parseEther("0.7"));
      expect(phiBS).to.equal(ethers.parseEther("0.2"));
      expect(phiTR).to.equal(ethers.parseEther("0.1"));
    });
  });

  describe("Capital stack getter", () => {
    beforeEach(async () => {
      await core.setCapitalStack(
        ethers.parseEther("5000"), // backstopNav
        ethers.parseEther("2000") // treasuryNav
      );
    });

    it("getCapitalStack returns both values", async () => {
      const [backstopNav, treasuryNav] = await core.getCapitalStack();

      expect(backstopNav).to.equal(ethers.parseEther("5000"));
      expect(treasuryNav).to.equal(ethers.parseEther("2000"));
    });
  });

  describe("Withdrawal lag getter", () => {
    it("getWithdrawalLagBatches returns correct value", async () => {
      await core.setWithdrawalLagBatches(5);
      expect(await core.getWithdrawalLagBatches()).to.equal(5);
    });
  });

  describe("Config change events", () => {
    it("emits RiskConfigUpdated on setRiskConfig", async () => {
      await expect(
        core.setRiskConfig(
          ethers.parseEther("0.3"),
          ethers.parseEther("1"),
          true
        )
      )
        .to.emit(core, "RiskConfigUpdated")
        .withArgs(ethers.parseEther("0.3"), ethers.parseEther("1"), true);
    });

    it("emits CapitalStackUpdated on setCapitalStack", async () => {
      await expect(
        core.setCapitalStack(
          ethers.parseEther("1000"),
          ethers.parseEther("500")
        )
      )
        .to.emit(core, "CapitalStackUpdated")
        .withArgs(ethers.parseEther("1000"), ethers.parseEther("500"));
    });

    it("emits WithdrawalLagUpdated on setWithdrawalLagBatches", async () => {
      await expect(core.setWithdrawalLagBatches(3))
        .to.emit(core, "WithdrawalLagUpdated")
        .withArgs(3);
    });

    it("emits LpShareTokenUpdated on setLpShareToken", async () => {
      const addr = ethers.Wallet.createRandom().address;
      await expect(core.setLpShareToken(addr))
        .to.emit(core, "LpShareTokenUpdated")
        .withArgs(addr);
    });

    it("emits ModulesUpdated on setModules", async () => {
      const addr1 = ethers.Wallet.createRandom().address;
      const addr2 = ethers.Wallet.createRandom().address;
      const addr3 = ethers.Wallet.createRandom().address;
      const addr4 = ethers.Wallet.createRandom().address;
      const addr5 = ethers.Wallet.createRandom().address;
      await expect(core.setModules(addr1, addr2, addr3, addr4, addr5))
        .to.emit(core, "ModulesUpdated")
        .withArgs(addr1, addr2, addr3, addr4, addr5);
    });
  });
});
