import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { MockERC20, SignalsCoreHarness } from "../../../typechain-types";

const usdc = (value: string) => ethers.parseUnits(value, 6);

describe("Capital Funding (Core)", () => {
  async function deployCoreFixture() {
    const [owner, user] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const paymentToken = (await MockERC20.deploy("USDC", "USDC", 6)) as MockERC20;

    const positionImplFactory = await ethers.getContractFactory("SignalsPosition");
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

    const LazyMulSegmentTree = await ethers.getContractFactory("LazyMulSegmentTree");
    const lazyLib = await LazyMulSegmentTree.deploy();

    const SignalsCoreHarnessFactory = await ethers.getContractFactory(
      "SignalsCoreHarness",
      {
        libraries: { LazyMulSegmentTree: await lazyLib.getAddress() },
      }
    );
    const coreImpl = await SignalsCoreHarnessFactory.deploy();
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

    const core = SignalsCoreHarnessFactory.attach(
      await proxy.getAddress()
    ) as SignalsCoreHarness;

    await position.setCore(await core.getAddress());

    const RiskModule = await ethers.getContractFactory("RiskModule");
    const riskModule = await RiskModule.deploy();

    const TradeModule = await ethers.getContractFactory("TradeModule", {
      libraries: { LazyMulSegmentTree: await lazyLib.getAddress() },
    });
    const tradeModule = await TradeModule.deploy();

    const MarketLifecycleModule = await ethers.getContractFactory("MarketLifecycleModule", {
      libraries: { LazyMulSegmentTree: await lazyLib.getAddress() },
    });
    const lifecycleModule = await MarketLifecycleModule.deploy();

    const LPVaultModule = await ethers.getContractFactory("LPVaultModule");
    const vaultModule = await LPVaultModule.deploy();

    const OracleModule = await ethers.getContractFactory("OracleModuleHarness");
    const oracleModule = await OracleModule.deploy();

    await core.setModules(
      await tradeModule.getAddress(),
      await lifecycleModule.getAddress(),
      await riskModule.getAddress(),
      await vaultModule.getAddress(),
      await oracleModule.getAddress()
    );

    await paymentToken.mint(await owner.getAddress(), usdc("100000"));
    await paymentToken.mint(await user.getAddress(), usdc("100000"));
    await paymentToken.connect(owner).approve(await core.getAddress(), ethers.MaxUint256);
    await paymentToken.connect(user).approve(await core.getAddress(), ethers.MaxUint256);

    return { owner, user, core, paymentToken };
  }

  it("allows permissionless backstop funding", async () => {
    const { user, core, paymentToken } = await loadFixture(deployCoreFixture);

    await expect(core.connect(user).fundBackstop(usdc("500")))
      .to.emit(core, "BackstopFunded")
      .withArgs(await user.getAddress(), usdc("500"), ethers.parseEther("500"));

    const [backstopNav] = await core.getCapitalStack();
    expect(backstopNav).to.equal(ethers.parseEther("500"));
    expect(await paymentToken.balanceOf(await core.getAddress())).to.equal(usdc("500"));
  });

  it("allows permissionless treasury funding", async () => {
    const { user, core, paymentToken } = await loadFixture(deployCoreFixture);

    await expect(core.connect(user).fundTreasury(usdc("250")))
      .to.emit(core, "TreasuryFunded")
      .withArgs(await user.getAddress(), usdc("250"), ethers.parseEther("250"));

    const [, treasuryNav] = await core.getCapitalStack();
    expect(treasuryNav).to.equal(ethers.parseEther("250"));
    expect(await paymentToken.balanceOf(await core.getAddress())).to.equal(usdc("250"));
  });

  it("restricts backstop withdrawal to owner", async () => {
    const { user, core } = await loadFixture(deployCoreFixture);

    await core.fundBackstop(usdc("100"));

    await expect(core.connect(user).withdrawBackstop(usdc("10")))
      .to.be.revertedWithCustomError(core, "OwnableUnauthorizedAccount")
      .withArgs(await user.getAddress());
  });

  it("withdraws backstop to owner and updates NAV", async () => {
    const { owner, core, paymentToken } = await loadFixture(deployCoreFixture);

    await core.fundBackstop(usdc("1000"));
    const ownerBefore = await paymentToken.balanceOf(await owner.getAddress());

    await expect(core.withdrawBackstop(usdc("400")))
      .to.emit(core, "BackstopWithdrawn")
      .withArgs(await owner.getAddress(), usdc("400"), ethers.parseEther("600"));

    const [backstopNav] = await core.getCapitalStack();
    expect(backstopNav).to.equal(ethers.parseEther("600"));
    expect(await paymentToken.balanceOf(await owner.getAddress())).to.equal(
      ownerBefore + usdc("400")
    );
  });

  it("withdraws treasury to owner and updates NAV", async () => {
    const { owner, core, paymentToken } = await loadFixture(deployCoreFixture);

    await core.fundTreasury(usdc("700"));
    const ownerBefore = await paymentToken.balanceOf(await owner.getAddress());

    await expect(core.withdrawTreasury(usdc("200")))
      .to.emit(core, "TreasuryWithdrawn")
      .withArgs(await owner.getAddress(), usdc("200"), ethers.parseEther("500"));

    const [, treasuryNav] = await core.getCapitalStack();
    expect(treasuryNav).to.equal(ethers.parseEther("500"));
    expect(await paymentToken.balanceOf(await owner.getAddress())).to.equal(
      ownerBefore + usdc("200")
    );
  });

  it("reverts when withdrawal exceeds free balance", async () => {
    const { core } = await loadFixture(deployCoreFixture);

    await core.fundBackstop(usdc("1000"));
    await core.harnessSetReserves(0n, 0n, usdc("900"));

    await expect(core.withdrawBackstop(usdc("200")))
      .to.be.revertedWithCustomError(core, "InsufficientFreeBalance")
      .withArgs(usdc("200"), usdc("100"));
  });
});
