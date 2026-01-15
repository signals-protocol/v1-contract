import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployTradeModuleSystem } from "../../helpers/deploy";
import { ONE_HOUR, WAD } from "../../helpers/constants";

const BPS_DENOM = 10_000n;
const WAD_BI = 1_000_000_000_000_000_000n;

function powWad(xWad: bigint, exp: number): bigint {
  let result = WAD_BI;
  let base = xWad;
  let e = exp;
  while (e > 0) {
    if (e & 1) {
      result = (result * base) / WAD_BI;
    }
    e >>= 1;
    if (e > 0) {
      base = (base * base) / WAD_BI;
    }
  }
  return result;
}

function expectedThetaFee(
  baseAmount: bigint,
  baseBps: bigint,
  thetaMaxBps: bigint,
  windowSeconds: bigint,
  beta: number,
  endTimestamp: bigint,
  now: bigint
): bigint {
  let tau = 0n;
  if (endTimestamp > now) {
    tau = endTimestamp - now;
  }

  let thetaBps = 0n;
  if (tau < windowSeconds) {
    const xWad = ((windowSeconds - tau) * WAD_BI) / windowSeconds;
    const xPow = powWad(xWad, beta);
    thetaBps = (thetaMaxBps * xPow) / WAD_BI;
  }

  const totalBps = baseBps + thetaBps;
  return (baseAmount * totalBps) / BPS_DENOM;
}

describe("ThetaTimeFeePolicy", () => {
  async function deployFixture() {
    const system = await deployTradeModuleSystem({
      markets: [
        {
          numBins: 4,
          tickSpacing: 1,
          minTick: 0,
          maxTick: 4,
          endOffset: ONE_HOUR * 2,
          liquidityParameter: WAD,
        },
      ],
      userCount: 1,
    });

    const { core } = system;
    const market = await core.harnessGetMarket(1);
    return { ...system, endTimestamp: BigInt(market.endTimestamp) };
  }

  it("applies base fee only when tau >= window", async () => {
    const { core, endTimestamp } = await deployFixture();
    const baseBps = 30n;
    const thetaMaxBps = 3000n;
    const window = BigInt(ONE_HOUR);
    const beta = 2;
    const baseAmount = 1_000_000n;

    const feePolicy = await (
      await ethers.getContractFactory("ThetaTimeFeePolicy")
    ).deploy(await core.getAddress(), baseBps, thetaMaxBps, window, beta);

    const now = BigInt(await time.latest());
    expect(endTimestamp - now).to.be.gte(window);

    const fee = await feePolicy.quoteFee({
      trader: ethers.ZeroAddress,
      marketId: 1,
      lowerTick: 0,
      upperTick: 4,
      quantity: 1_000_000,
      baseAmount,
      isBuy: true,
      context: ethers.ZeroHash,
    });

    const expected = expectedThetaFee(
      baseAmount,
      baseBps,
      thetaMaxBps,
      window,
      beta,
      endTimestamp,
      now
    );
    expect(fee).to.equal(expected);
  });

  it("ramps theta within window", async () => {
    const { core, endTimestamp } = await deployFixture();
    const baseBps = 30n;
    const thetaMaxBps = 3000n;
    const window = BigInt(ONE_HOUR);
    const beta = 2;
    const baseAmount = 2_500_000n;

    const feePolicy = await (
      await ethers.getContractFactory("ThetaTimeFeePolicy")
    ).deploy(await core.getAddress(), baseBps, thetaMaxBps, window, beta);

    const targetNow = endTimestamp - window / 2n;
    await time.setNextBlockTimestamp(Number(targetNow));
    await ethers.provider.send("evm_mine", []);

    const now = BigInt(await time.latest());
    const fee = await feePolicy.quoteFee({
      trader: ethers.ZeroAddress,
      marketId: 1,
      lowerTick: 0,
      upperTick: 4,
      quantity: 1_000_000,
      baseAmount,
      isBuy: true,
      context: ethers.ZeroHash,
    });

    const expected = expectedThetaFee(
      baseAmount,
      baseBps,
      thetaMaxBps,
      window,
      beta,
      endTimestamp,
      now
    );
    expect(fee).to.equal(expected);
  });

  it("applies max theta at tau=0", async () => {
    const { core, endTimestamp } = await deployFixture();
    const baseBps = 30n;
    const thetaMaxBps = 3000n;
    const window = BigInt(ONE_HOUR);
    const beta = 4;
    const baseAmount = 5_000_000n;

    const feePolicy = await (
      await ethers.getContractFactory("ThetaTimeFeePolicy")
    ).deploy(await core.getAddress(), baseBps, thetaMaxBps, window, beta);

    await time.setNextBlockTimestamp(Number(endTimestamp));
    await ethers.provider.send("evm_mine", []);

    const now = BigInt(await time.latest());
    const fee = await feePolicy.quoteFee({
      trader: ethers.ZeroAddress,
      marketId: 1,
      lowerTick: 0,
      upperTick: 4,
      quantity: 1_000_000,
      baseAmount,
      isBuy: true,
      context: ethers.ZeroHash,
    });

    const expected = expectedThetaFee(
      baseAmount,
      baseBps,
      thetaMaxBps,
      window,
      beta,
      endTimestamp,
      now
    );
    expect(fee).to.equal(expected);
  });

  it("returns zero for zero baseAmount", async () => {
    const { core } = await deployFixture();
    const feePolicy = await (
      await ethers.getContractFactory("ThetaTimeFeePolicy")
    ).deploy(await core.getAddress(), 10n, 100n, BigInt(ONE_HOUR), 1);

    const fee = await feePolicy.quoteFee({
      trader: ethers.ZeroAddress,
      marketId: 1,
      lowerTick: 0,
      upperTick: 4,
      quantity: 1_000_000,
      baseAmount: 0,
      isBuy: true,
      context: ethers.ZeroHash,
    });

    expect(fee).to.equal(0n);
  });

  it("rejects invalid constructor params", async () => {
    const { core } = await deployFixture();
    const factory = await ethers.getContractFactory("ThetaTimeFeePolicy");

    await expect(
      factory.deploy(ethers.ZeroAddress, 10n, 100n, BigInt(ONE_HOUR), 1)
    ).to.be.revertedWith("core=0");

    await expect(
      factory.deploy(await core.getAddress(), 10n, 100n, 0n, 1)
    ).to.be.revertedWith("window=0");

    await expect(
      factory.deploy(await core.getAddress(), 10n, 100n, BigInt(ONE_HOUR), 0)
    ).to.be.revertedWith("beta<1");

    await expect(
      factory.deploy(await core.getAddress(), 9_000n, 2_000n, BigInt(ONE_HOUR), 1)
    ).to.be.revertedWith("rate>100%");
  });

  it("descriptor encodes params", async () => {
    const { core } = await deployFixture();
    const feePolicy = await (
      await ethers.getContractFactory("ThetaTimeFeePolicy")
    ).deploy(await core.getAddress(), 30n, 3000n, BigInt(ONE_HOUR), 4);

    const raw = await feePolicy.descriptor();
    const parsed = JSON.parse(raw);
    expect(parsed.policy).to.equal("theta-time");
    expect(parsed.params.baseBps).to.equal("30");
    expect(parsed.params.thetaMaxBps).to.equal("3000");
    expect(parsed.params.windowSec).to.equal(String(ONE_HOUR));
    expect(parsed.params.beta).to.equal("4");
  });
});
