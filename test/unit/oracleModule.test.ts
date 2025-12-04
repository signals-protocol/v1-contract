import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  MarketLifecycleModule,
  MockPaymentToken,
  MockSignalsPosition,
  OracleModule,
  SignalsCoreHarness,
} from "../../typechain-types";
import { ISignalsCore } from "../../typechain-types/contracts/core/SignalsCore";

const abiCoder = ethers.AbiCoder.defaultAbiCoder();

function buildDigest(
  chainId: bigint,
  core: string,
  marketId: number,
  settlementValue: bigint,
  priceTimestamp: bigint
) {
  const encoded = abiCoder.encode(
    ["uint256", "address", "uint256", "int256", "uint64"],
    [chainId, core, marketId, settlementValue, priceTimestamp]
  );
  return ethers.keccak256(encoded);
}

describe("OracleModule", () => {
  async function setup() {
    const [owner, oracleSigner, other] = await ethers.getSigners();
    const payment = await (await ethers.getContractFactory("MockPaymentToken")).deploy();
    const position = await (await ethers.getContractFactory("MockSignalsPosition")).deploy();
    const lazyLib = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();

    const lifecycleImpl = (await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy()) as MarketLifecycleModule;
    const oracleModule = (await (await ethers.getContractFactory("OracleModule")).deploy()) as OracleModule;

    const coreImpl = (await (
      await ethers.getContractFactory("SignalsCoreHarness", {
        libraries: { LazyMulSegmentTree: lazyLib.target },
      })
    ).deploy()) as SignalsCoreHarness;

    const initData = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      120,
      300,
    ]);
    const proxy = await (await ethers.getContractFactory("TestERC1967Proxy")).deploy(coreImpl.target, initData);
    const core = (await ethers.getContractAt("SignalsCoreHarness", proxy.target)) as SignalsCoreHarness;

    await core.setModules(
      ethers.ZeroAddress,
      lifecycleImpl.target,
      ethers.ZeroAddress,
      ethers.ZeroAddress,
      oracleModule.target
    );
    await core.setOracleConfig(oracleSigner.address);

    const now = BigInt(await time.latest());
    const market: ISignalsCore.MarketStruct = {
      isActive: true,
      settled: false,
      snapshotChunksDone: false,
      numBins: 4,
      openPositionCount: 0,
      snapshotChunkCursor: 0,
      startTimestamp: now - 100n,
      endTimestamp: now + 200n,
      settlementTimestamp: now + 200n,
      minTick: 0,
      maxTick: 4,
      tickSpacing: 1,
      settlementTick: 0,
      settlementValue: 0,
      liquidityParameter: ethers.parseEther("1"),
      feePolicy: ethers.ZeroAddress,
    };
    await core.harnessSetMarket(1, market);

    const { chainId } = await ethers.provider.getNetwork();

    return {
      owner,
      oracleSigner,
      other,
      core,
      oracleModule,
      market,
      chainId: chainId,
    };
  }

  it("records candidate price with valid signature and window", async () => {
    const { core, oracleModule, oracleSigner, chainId, market } = await setup();
    const oracleEvents = oracleModule.attach(await core.getAddress());
    const priceTimestamp = market.endTimestamp + 10n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));

    const digest = buildDigest(chainId, await core.getAddress(), 1, 2n, priceTimestamp);
    const signature = await oracleSigner.signMessage(ethers.getBytes(digest));

    await expect(core.submitSettlementPrice(1, 2n, priceTimestamp, signature))
      .to.emit(oracleEvents, "SettlementPriceSubmitted")
      .withArgs(1, 2, priceTimestamp, oracleSigner.address);

    const [price, ts] = await core.getSettlementPrice.staticCall(1, 0);
    expect(price).to.equal(2);
    expect(ts).to.equal(priceTimestamp);
  });

  it("reverts on invalid signer", async () => {
    const { core, oracleModule, other, chainId, market } = await setup();
    const priceTimestamp = market.endTimestamp + 5n;
    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));

    const digest = buildDigest(chainId, await core.getAddress(), 1, 3n, priceTimestamp);
    const badSignature = await other.signMessage(ethers.getBytes(digest));

    await expect(core.submitSettlementPrice(1, 3n, priceTimestamp, badSignature))
      .to.be.revertedWithCustomError(oracleModule, "SettlementOracleSignatureInvalid")
      .withArgs(other.address);
  });

  it("enforces submit window bounds", async () => {
    const { core, oracleModule, oracleSigner, chainId, market } = await setup();
    const tooEarlyTs = market.endTimestamp - 1n;
    await time.setNextBlockTimestamp(Number(tooEarlyTs + 1n));
    const earlyDigest = buildDigest(chainId, await core.getAddress(), 1, 1n, tooEarlyTs);
    const earlySig = await oracleSigner.signMessage(ethers.getBytes(earlyDigest));

    await expect(core.submitSettlementPrice(1, 1n, tooEarlyTs, earlySig)).to.be.revertedWithCustomError(
      oracleModule,
      "SettlementTooEarly"
    );

    const lateTs = market.endTimestamp + 121n; // submitWindow = 120
    await time.setNextBlockTimestamp(Number(lateTs + 1n));
    const lateDigest = buildDigest(chainId, await core.getAddress(), 1, 1n, lateTs);
    const lateSig = await oracleSigner.signMessage(ethers.getBytes(lateDigest));

    await expect(core.submitSettlementPrice(1, 1n, lateTs, lateSig)).to.be.revertedWithCustomError(
      oracleModule,
      "SettlementFinalizeWindowClosed"
    );
  });

  it("getSettlementPrice reverts when no candidate recorded", async () => {
    const { core, oracleModule } = await setup();
    await expect(core.getSettlementPrice(1, 0)).to.be.revertedWithCustomError(
      oracleModule,
      "SettlementOracleCandidateMissing"
    );
  });
});
