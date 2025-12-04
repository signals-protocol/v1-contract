import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  MarketLifecycleModule,
  MockPaymentToken,
  MockSignalsPosition,
  OracleModule,
  TradeModule,
  SignalsCore,
} from "../../typechain-types";

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
    const position = await (await ethers.getContractFactory("MockSignalsPosition")).deploy();
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

    const coreImpl = (await (await ethers.getContractFactory("SignalsCore")).deploy()) as SignalsCore;
    const submitWindow = 300;
    const finalizeDeadline = 60;
    const initData = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      submitWindow,
      finalizeDeadline,
    ]);
    const proxy = await (await ethers.getContractFactory("TestERC1967Proxy")).deploy(coreImpl.target, initData);
    const core = (await ethers.getContractAt("SignalsCore", proxy.target)) as SignalsCore;
    await core.setModules(tradeModule.target, lifecycleModule.target, ethers.ZeroAddress, ethers.ZeroAddress, oracleModule.target);
    await core.setOracleConfig(oracleSigner.address);

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
      owner,
      user,
      oracleSigner,
      payment,
      position,
      core,
      lifecycleModule,
      submitWindow,
      finalizeDeadline,
      chainId,
    } = await setup();

    const lifecycleEvents = lifecycleModule.attach(await core.getAddress());

    const now = BigInt(await time.latest());
    const start = now - 50n;
    const end = now + 200n;
    const settlementTs = end + 10n;
    const marketId = await core.createMarket.staticCall(
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
      core.createMarket(0, 4, 1, Number(start), Number(end), Number(settlementTs), 4, ethers.parseEther("1"), ethers.ZeroAddress)
    ).to.emit(lifecycleEvents, "MarketCreated");

    // fund and approve user
    await payment.transfer(user.address, 10_000_000n);
    await payment.connect(user).approve(await core.getAddress(), ethers.MaxUint256);

    // open position
    const positionId = await position.nextId();
    await core.connect(user).openPosition(marketId, 0, 4, 1_000, 5_000_000);
    let market = await core.markets(marketId);
    expect(market.openPositionCount).to.equal(1);

    // submit oracle price after market end
    const priceTimestamp = end + 5n;
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
});
