import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  MarketLifecycleModule,
  OracleModule,
  TradeModule,
  SignalsCoreHarness,
  SignalsPosition,
  TestERC1967Proxy,
} from "../../../typechain-types";

const abiCoder = ethers.AbiCoder.defaultAbiCoder();

function buildDigest(
  chainId: bigint,
  core: string,
  marketId: bigint | number,
  settlementValue: bigint,
  priceTimestamp: bigint
) {
  const id = BigInt(marketId);
  const encoded = abiCoder.encode(
    ["uint256", "address", "uint256", "int256", "uint64"],
    [chainId, core, id, settlementValue, priceTimestamp]
  );
  return ethers.keccak256(encoded);
}

describe("Lifecycle + Trade integration", () => {
  async function setup() {
    const [owner, user, oracleSigner] = await ethers.getSigners();
    const payment = await (await ethers.getContractFactory("MockPaymentToken")).deploy();
    const positionImplFactory = await ethers.getContractFactory("SignalsPosition");
    const positionImpl = await positionImplFactory.deploy();
    await positionImpl.waitForDeployment();
    const positionInit = positionImplFactory.interface.encodeFunctionData("initialize", [owner.address]);
    const positionProxy = (await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(await positionImpl.getAddress(), positionInit)) as TestERC1967Proxy;
    const position = (await ethers.getContractAt(
      "SignalsPosition",
      await positionProxy.getAddress()
    )) as SignalsPosition;
    const lazyLib = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();

    const tradeModule = (await (
      await ethers.getContractFactory("TradeModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy()) as TradeModule;
    const lifecycleModule = (await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy()) as MarketLifecycleModule;
    const oracleModule = (await (await ethers.getContractFactory("OracleModule")).deploy()) as OracleModule;

    const coreImpl = (await (await ethers.getContractFactory("SignalsCoreHarness", { libraries: { LazyMulSegmentTree: lazyLib.target } })).deploy()) as SignalsCoreHarness;
    const submitWindow = 300;
    const finalizeDeadline = 60;
    const initData = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      await position.getAddress(),
      submitWindow,
      finalizeDeadline,
    ]);
    const proxy = (await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(coreImpl.target, initData)) as TestERC1967Proxy;
    const core = (await ethers.getContractAt("SignalsCoreHarness", await proxy.getAddress())) as SignalsCoreHarness;
    await core.setModules(tradeModule.target, lifecycleModule.target, ethers.ZeroAddress, ethers.ZeroAddress, oracleModule.target);
    await core.setOracleConfig(oracleSigner.address);
    await position.connect(owner).setCore(await core.getAddress());

    const { chainId } = await ethers.provider.getNetwork();

    return {
      owner,
      user,
      oracleSigner,
      payment,
      position,
      tradeModule,
      lifecycleModule,
      oracleModule,
      core,
      submitWindow,
      finalizeDeadline,
      chainId,
    };
  }

  it("runs create -> trade -> settlement -> snapshot -> claim flow", async () => {
    const {
      user,
      oracleSigner,
      payment,
      position,
      core,
      lifecycleModule,
      finalizeDeadline,
      chainId,
    } = await setup();

    const lifecycleEvents = lifecycleModule.attach(await core.getAddress());

    const now = BigInt(await time.latest());
    const start = now - 50n;
    const end = now + 200n;
    const settlementTs = end + 10n;
    const marketId = await core.createMarketUniform.staticCall(
      0,
      4,
      1,
      Number(start),
      Number(end),
      Number(settlementTs),
      4,
      ethers.parseEther("1"),
      ethers.ZeroAddress
    );
    await expect(
      core.createMarketUniform(0, 4, 1, Number(start), Number(end), Number(settlementTs), 4, ethers.parseEther("1"), ethers.ZeroAddress)
    ).to.emit(lifecycleEvents, "MarketCreated");

    // fund and approve user
    await payment.transfer(user.address, 10_000_000n);
    await payment.connect(user).approve(await core.getAddress(), ethers.MaxUint256);

    // open position
    const positionId = await position.nextId();
    await core.connect(user).openPosition(marketId, 0, 4, 1_000, 5_000_000);
    let market = await core.markets(marketId);
    expect(market.openPositionCount).to.equal(1);

    // submit oracle price after settlementTimestamp (Tset)
    const priceTimestamp = settlementTs + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    const digest = buildDigest(chainId, await core.getAddress(), marketId, 2n, priceTimestamp);
    const signature = await oracleSigner.signMessage(ethers.getBytes(digest));
    await core.submitSettlementPrice(marketId, 2n, priceTimestamp, signature);

    // settle
    await time.setNextBlockTimestamp(Number(priceTimestamp + 2n));
    await core.settleMarket(marketId);
    market = await core.markets(marketId);
    expect(market.settled).to.equal(true);
    expect(market.snapshotChunksDone).to.equal(false);

    // request settlement chunks (openPositionCount = 1 => 1 chunk)
    await expect(core.requestSettlementChunks(marketId, 5))
      .to.emit(lifecycleEvents, "SettlementChunkRequested")
      .withArgs(marketId, 0);
    market = await core.markets(marketId);
    expect(market.snapshotChunksDone).to.equal(true);

    // wait for claim window and claim payout
    await time.increase(finalizeDeadline + 1);
    const balBefore = await payment.balanceOf(user.address);
    await core.connect(user).claimPayout(positionId);
    const balAfter = await payment.balanceOf(user.address);
    expect(balAfter - balBefore).to.equal(1_000);
    expect(await position.exists(positionId)).to.equal(false);
  });

  it("burns loser positions with zero payout and prevents double-claim", async () => {
    const {
      user,
      oracleSigner,
      payment,
      position,
      core,
      lifecycleModule,
      chainId,
    } = await setup();

    const lifecycleEvents = lifecycleModule.attach(await core.getAddress());

    const now = BigInt(await time.latest());
    const start = now - 50n;
    const end = now + 200n;
    const settlementTs = end + 10n;
    await core.createMarketUniform(0, 4, 1, Number(start), Number(end), Number(settlementTs), 4, ethers.parseEther("1"), ethers.ZeroAddress);

    await payment.transfer(user.address, 10_000_000n);
    await payment.connect(user).approve(await core.getAddress(), ethers.MaxUint256);

    const pos1 = await position.nextId(); // winner
    await core.connect(user).openPosition(1, 0, 4, 1_000, 5_000_000);
    const pos2 = Number(pos1) + 1; // loser (upper range)
    await core.connect(user).openPosition(1, 3, 4, 1_000, 5_000_000);

    // priceTimestamp must be >= Tset (settlementTs)
    const priceTimestamp = settlementTs + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    const digest = buildDigest(chainId, await core.getAddress(), 1, 1n, priceTimestamp);
    const signature = await oracleSigner.signMessage(ethers.getBytes(digest));
    await core.submitSettlementPrice(1, 1n, priceTimestamp, signature);
    await time.setNextBlockTimestamp(Number(priceTimestamp + 2n));
    await core.settleMarket(1);
    await expect(core.requestSettlementChunks(1, 5))
      .to.emit(lifecycleEvents, "SettlementChunkRequested")
      .withArgs(1, 0);

    await time.increase(61); // finalize window

    const balBefore = await payment.balanceOf(user.address);
    await core.connect(user).claimPayout(pos1);
    await core.connect(user).claimPayout(pos2);
    const balAfter = await payment.balanceOf(user.address);
    expect(balAfter - balBefore).to.equal(1_000); // loser payout zero
    expect(await position.exists(pos1)).to.equal(false);
    expect(await position.exists(pos2)).to.equal(false);

    await expect(core.connect(user).claimPayout(pos1)).to.be.reverted;
  });

  it("enforces time gates for trading, settlement, and claim windows", async () => {
    const { user, oracleSigner, payment, core, chainId } = await setup();
    const now = BigInt(await time.latest());
    const start = now + 100n;
    const end = start + 100n;
    const settlementTs = end + 50n;
    await core.createMarketUniform(0, 4, 1, Number(start), Number(end), Number(settlementTs), 4, ethers.parseEther("1"), ethers.ZeroAddress);

    await payment.transfer(user.address, 10_000_000n);
    await payment.connect(user).approve(await core.getAddress(), ethers.MaxUint256);

    // too early to trade
    await expect(core.connect(user).openPosition(1, 0, 4, 1_000, 5_000_000)).to.be.reverted;

    await time.setNextBlockTimestamp(Number(start + 1n));
    await core.connect(user).openPosition(1, 0, 4, 1_000, 5_000_000);

    // after endTimestamp trading should revert
    await time.setNextBlockTimestamp(Number(end + 1n));
    await expect(core.connect(user).increasePosition(1, 1_000, 5_000_000)).to.be.reverted;

    // settlement too early
    await expect(core.settleMarket(1)).to.be.reverted;

    // submit settlement and settle within window (priceTimestamp >= Tset)
    const priceTimestamp = settlementTs + 10n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    const digest = buildDigest(chainId, await core.getAddress(), 1, 1n, priceTimestamp);
    const sig = await oracleSigner.signMessage(ethers.getBytes(digest));
    await core.submitSettlementPrice(1, 1n, priceTimestamp, sig);
    await core.settleMarket(1);

    // claim too early (claim gate = settlementTimestamp + finalizeDeadline(60))
    await expect(core.connect(user).claimPayout(1)).to.be.reverted;

    await time.increase(61);
    await core.connect(user).claimPayout(1);
  });
});
