import { expect } from "chai";
import { ethers } from "hardhat";
import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import {
  LazyMulSegmentTree,
  LPVaultModule,
  MarketLifecycleModule,
  MockERC20,
  MockSignalsPosition,
  OracleModule,
  SignalsCoreHarness,
  TestERC1967Proxy,
} from "../../../typechain-types";

const abiCoder = ethers.AbiCoder.defaultAbiCoder();
const BATCH_SECONDS = 86_400n;
const WAD = ethers.parseEther("1");

function buildOracleDigest(
  chainId: bigint,
  core: string,
  marketId: bigint,
  settlementValue: bigint,
  priceTimestamp: bigint
) {
  const encoded = abiCoder.encode(
    ["uint256", "address", "uint256", "int256", "uint64"],
    [chainId, core, marketId, settlementValue, priceTimestamp]
  );
  return ethers.keccak256(encoded);
}

describe("VaultWithMarkets E2E", () => {
  async function deploySystem() {
    const [owner, seeder, oracleSigner] = await ethers.getSigners();
    const { chainId } = await ethers.provider.getNetwork();

    // Use 18-decimal token for vault accounting tests (WAD-aligned)
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    // Phase 6: Use 6-decimal token as per WP v2 Sec 6.2 (paymentToken = USDC6)
    const payment = (await MockERC20Factory.deploy(
      "MockVaultToken",
      "MVT",
      6
    )) as MockERC20;

    const position = (await (
      await ethers.getContractFactory("MockSignalsPosition")
    ).deploy()) as MockSignalsPosition;

    const lazy = (await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy()) as LazyMulSegmentTree;
    const lifecycle = (await (
      await ethers.getContractFactory("MarketLifecycleModule", {
        libraries: { LazyMulSegmentTree: lazy.target },
      })
    ).deploy()) as MarketLifecycleModule;

    const oracle = (await (await ethers.getContractFactory("OracleModule")).deploy()) as OracleModule;
    const vault = (await (await ethers.getContractFactory("LPVaultModule")).deploy()) as LPVaultModule;

    const coreImpl = (await (
      await ethers.getContractFactory("SignalsCoreHarness", {
        libraries: { LazyMulSegmentTree: lazy.target },
      })
    ).deploy()) as SignalsCoreHarness;

    const submitWindow = 300;
    const finalizeDeadline = 60;
    const initData = coreImpl.interface.encodeFunctionData("initialize", [
      payment.target,
      position.target,
      submitWindow,
      finalizeDeadline,
    ]);

    const proxy = (await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(coreImpl.target, initData)) as TestERC1967Proxy;

    const core = (await ethers.getContractAt(
      "SignalsCoreHarness",
      await proxy.getAddress()
    )) as SignalsCoreHarness;

    await core.setModules(
      ethers.ZeroAddress,
      lifecycle.target,
      ethers.ZeroAddress,
      vault.target,
      oracle.target
    );
    await core.setOracleConfig(oracleSigner.address);

    // Vault config needed for batch processing
    await core.setMinSeedAmount(ethers.parseEther("100"));
    await core.setWithdrawalLagBatches(0);
    await core.setFeeWaterfallConfig(
      ethers.parseEther("-0.2"), // pdd
      0n, // rhoBS
      ethers.parseEther("0.8"), // phiLP
      ethers.parseEther("0.1"), // phiBS
      ethers.parseEther("0.1") // phiTR
    );
    await core.setCapitalStack(0n, 0n);

    return { owner, seeder, oracleSigner, chainId, core, payment };
  }

  it("settleMarket records daily PnL and vault consumes it in processDailyBatch", async () => {
    const { owner, seeder, oracleSigner, chainId, core, payment } = await loadFixture(
      deploySystem
    );

    // Fix timestamp so batchId (day-key) is deterministic and monotonic
    const latest = BigInt(await time.latest());
    const seedTime = (latest / BATCH_SECONDS + 1n) * BATCH_SECONDS + 1_000n;
    const dayKey = seedTime / BATCH_SECONDS;
    const expectedFirstBatchId = dayKey;

    // Seed vault (sets currentBatchId = dayKey - 1)
    const seedAmount = ethers.parseEther("1000");
    await payment.mint(seeder.address, seedAmount);
    await payment.connect(seeder).approve(await core.getAddress(), ethers.MaxUint256);

    await time.setNextBlockTimestamp(Number(seedTime));
    await core.connect(seeder).seedVault(seedAmount);

    const currentBatchId = await core.currentBatchId();
    expect(currentBatchId).to.equal(expectedFirstBatchId - 1n);

    // Create a market that settles on the same day-key as the first vault batch
    // Use a Tset after seeding to keep block timestamps monotonic.
    const tSet = seedTime + 10n;
    const start = tSet - 200n;
    const end = tSet - 20n;

    const marketId = await core.createMarket.staticCall(
      0,
      4,
      1,
      Number(start),
      Number(end),
      Number(tSet),
      4,
      WAD,
      ethers.ZeroAddress
    );
    await core.createMarket(0, 4, 1, Number(start), Number(end), Number(tSet), 4, WAD, ethers.ZeroAddress);

    // Manipulate tree state to create non-zero P&L at settlement
    // Z_start = 4e18, Z_end = 5e18 → L_t > 0
    await core.harnessSeedTree(marketId, [
      2n * WAD,
      1n * WAD,
      1n * WAD,
      1n * WAD,
    ]);

    const batchId = tSet / BATCH_SECONDS;
    expect(batchId).to.equal(expectedFirstBatchId);

    // Submit oracle price candidate within window [Tset, Tset + submitWindow]
    const priceTimestamp = tSet + 1n;
    const digest = buildOracleDigest(chainId, await core.getAddress(), marketId, 1n, priceTimestamp);
    const sig = await oracleSigner.signMessage(ethers.getBytes(digest));

    await time.setNextBlockTimestamp(Number(priceTimestamp + 1n));
    await core.submitSettlementPrice(marketId, 1n, Number(priceTimestamp), sig);

    // Finalize settlement and record P&L into _dailyPnl[batchId]
    await time.setNextBlockTimestamp(Number(priceTimestamp + 2n));
    await core.connect(owner).settleMarket(marketId);

    const [ltBefore, ftotBefore, , , , , processedBefore] = await core.getDailyPnl.staticCall(batchId);
    expect(processedBefore).to.equal(false);
    expect(ftotBefore).to.equal(0n);
    expect(ltBefore).to.not.equal(0n);

    const navBefore = await core.getVaultNav.staticCall();
    await core.processDailyBatch(batchId);
    const navAfter = await core.getVaultNav.staticCall();

    expect(navAfter).to.not.equal(navBefore);

    const [, , , , , , processedAfter] = await core.getDailyPnl.staticCall(batchId);
    expect(processedAfter).to.equal(true);
    expect(await core.currentBatchId()).to.equal(batchId);
  });
});

