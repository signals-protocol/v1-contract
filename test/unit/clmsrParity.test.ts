import { expect } from "chai";
import { BigNumberish, ContractFactory } from "ethers";
import { ethers } from "hardhat";
import Big from "big.js";
import fs from "fs";
import path from "path";

// SDK (v0 reference implementation)
// We call into the published JS SDK that ships alongside signals-v0 to obtain
// parity expectations without re-copying v0 contracts into the repo.
// NOTE: quantities/costs in the SDK are in micro-USDC (6 decimals).
// WAD values are 1e18 and conversion helpers live in MathUtils.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const sdk = require("../../signals-v0/clmsr-sdk/dist");
const { CLMSRSDK, mapMarket, mapDistribution, MathUtils, toWAD } = sdk;

const WAD = ethers.parseEther("1");
// FixedPointMathU exp/ln는 1e-8 근처 오차가 있을 수 있으므로 여유 있게 허용
const TOLERANCE = ethers.parseEther("0.00000003"); // 3e-8 WAD tolerance
const SAFE_EXP_TOLERANCE = ethers.parseEther("0.000001"); // safeExp parity 허용 오차(1e-6)

function toBN(value: BigNumberish) {
  return BigInt(value.toString());
}

function approx(actual: BigNumberish, expected: BigNumberish, tol: BigNumberish = TOLERANCE) {
  const a = toBN(actual);
  const e = toBN(expected);
  const diff = a >= e ? a - e : e - a;
  expect(diff <= toBN(tol), `expected ${a.toString()} ≈ ${e.toString()} (diff ${diff.toString()})`).to.be.true;
}

// exp helper with 18-decimal fixed result
function wadExp(x: number): bigint {
  const val = Math.exp(x);
  return ethers.parseUnits(val.toString(), 18);
}

describe("CLMSR SDK parity and invariants (Phase 3-0 harness)", () => {
  const alpha = WAD; // 1.0
  const loBin = 0;
  const hiBin = 3; // 4 bins total
  const qty = WAD; // 1.0

  const baseFactors = [WAD, WAD, WAD, WAD]; // uniform distribution, sum = 4 WAD

  async function deployHarness() {
    const lazyLib = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();
    const Factory = await ethers.getContractFactory("ClmsrMathHarness", {
      libraries: {
        LazyMulSegmentTree: lazyLib.target,
      },
    });
    const harness = await Factory.deploy();
    await harness.seed(baseFactors);
    return harness;
  }

  it("matches closed-form cost/proceeds for symmetric buy/sell", async () => {
    const harness = await deployHarness();
    // For uniform distribution and qty=1, alpha=1:
    // cost = alpha * ln( (affected * exp(1)) / affected ) = 1e18
    const expected = WAD;
    const cost = await harness.quoteBuy(alpha, loBin, hiBin, qty);
    approx(cost, expected);

    const proceeds = await harness.quoteSell(alpha, loBin, hiBin, qty);
    approx(proceeds, expected);
  });

  it("round-trips quantity -> cost -> quantity within tolerance", async () => {
    const harness = await deployHarness();
    const cost = await harness.quoteBuy(alpha, loBin, hiBin, qty);
    const quantityBack = await harness.quantityFromCost(alpha, loBin, hiBin, cost);
    approx(quantityBack, qty);
  });

  it("e2e open->close restores distribution (simulated apply factors)", async () => {
    const harness = await deployHarness();
    const halfQty = WAD / 2n; // 0.5
    const factor = wadExp(0.5); // exp(q/alpha) with q=0.5

    const rootBefore = await harness.cachedRootSum();
    // Buy: quote then apply factor to mutate tree (simulating stateful trade)
    const cost = await harness.quoteBuy(alpha, loBin, hiBin, halfQty);
    await harness.applyRangeFactor(loBin, hiBin, factor);
    const rootAfterBuy = await harness.cachedRootSum();
    const expectedAfterBuy = (rootBefore * factor) / WAD;
    approx(rootAfterBuy, expectedAfterBuy, TOLERANCE * 10n);

    // Sell the same quantity: quote then apply inverse factor
    const proceeds = await harness.quoteSell(alpha, loBin, hiBin, halfQty);
    const inverseFactor = (WAD * WAD) / factor;
    await harness.applyRangeFactor(loBin, hiBin, inverseFactor);
    const rootAfterSell = await harness.cachedRootSum();
    approx(rootAfterSell, rootBefore, TOLERANCE * 10n);

    // Cost and proceeds should be ~symmetric for this round-trip
    approx(cost, proceeds, TOLERANCE * 10n);
  });

  it("round-trips on a non-uniform distribution (fuzz-lite)", async () => {
    const customFactors = [WAD, WAD * 2n, WAD * 3n, WAD * 5n]; // sum = 11 WAD
    const harness = await deployHarness();
    await harness.seed(customFactors);

    const q = ethers.parseEther("0.42"); // arbitrary qty
    const cost = await harness.quoteBuy(alpha, loBin + 1, hiBin, q); // affect bins 1..3
    const qtyBack = await harness.quantityFromCost(alpha, loBin + 1, hiBin, cost);
    approx(qtyBack, q, TOLERANCE * 10n);

    // Larger quantity should cost more (monotonicity sanity)
    const q2 = ethers.parseEther("0.84");
    const cost2 = await harness.quoteBuy(alpha, loBin + 1, hiBin, q2);
    expect(toBN(cost2)).to.be.greaterThan(toBN(cost));
  });
});

describe("CLMSR SDK parity (calculate* level)", () => {
  const sdkClient = new CLMSRSDK();
  const alphaWad = BigInt(toWAD("1").toString());

  const market = mapMarket({
    liquidityParameter: toWAD("1").toString(),
    minTick: 0,
    maxTick: 4,
    tickSpacing: 1,
    feePolicyDescriptor: "", // no fee
  });

  const distribution = mapDistribution({
    totalSum: toWAD("4").toString(),
    binFactors: [toWAD("1"), toWAD("1"), toWAD("1"), toWAD("1")].map((b: any) => b.toString()),
  });

  async function deployHarnessWithUniform() {
    const lazyLib = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();
    const Factory = await ethers.getContractFactory("ClmsrMathHarness", {
      libraries: { LazyMulSegmentTree: lazyLib.target },
    });
    const harness = await Factory.deploy();
    await harness.seed([WAD, WAD, WAD, WAD]);
    return harness;
  }

  function bigToBigInt(b: any): bigint {
    return BigInt(new Big(b.toString()).round(0, Big.roundHalfUp).toString());
  }

  function mulWadNearest(a: bigint, b: bigint): bigint {
    // (a * b) / WAD with nearest rounding (ties up) to mirror FixedPointMathU.wMulNearest
    const half = WAD / 2n;
    return (a * b + half) / WAD;
  }

  it("matches SDK calculateOpenCost & quantityFromCost (fee=0)", async () => {
    const harness = await deployHarnessWithUniform();
    const quantity6 = BigInt(1_000_000); // 1 USDC

    const sdkOpen = sdkClient.calculateOpenCost(0, 4, quantity6.toString(), distribution, market);
    const costWad = await harness.quoteBuy(alphaWad, 0, 3, MathUtils.toWad(new Big(quantity6.toString())).toString());
    const harnessCost6 = MathUtils.fromWadRoundUp(new Big(costWad.toString()));

    // cost parity (micro-USDC)
    const sdkCost6 = new Big(sdkOpen.cost.toString());
    const diffCost = harnessCost6.minus(sdkCost6).abs();
    expect(diffCost.lte(1), `cost mismatch ${harnessCost6.toString()} vs ${sdkCost6.toString()}`).to.be.true;

    // quantityFromCost parity (using the SDK cost as input)
    const sdkQty = sdkClient.calculateQuantityFromCost(0, 4, sdkOpen.cost.toString(), distribution, market);
    const qtyWad = await harness.quantityFromCost(
      alphaWad,
      0,
      3,
      MathUtils.toWad(new Big(sdkOpen.cost.toString())).toString()
    );
    const harnessQty6 = MathUtils.fromWadNearest(new Big(qtyWad.toString()));
    const sdkQty6 = new Big(sdkQty.quantity.toString());
    const diffQty = harnessQty6.minus(sdkQty6).abs();
    expect(diffQty.lte(1), `quantity mismatch ${harnessQty6.toString()} vs ${sdkQty6.toString()}`).to.be.true;
  });

  it("matches SDK decrease/close proceeds (fee=0)", async () => {
    const harness = await deployHarnessWithUniform();
    const positionQty6 = BigInt(2_000_000); // 2 USDC position
    const sellQty6 = BigInt(500_000); // sell 0.5 USDC

    const sellQtyWad = MathUtils.toWad(new Big(sellQty6.toString()));
    const positionQtyWad = MathUtils.toWad(new Big(positionQty6.toString()));

    // Simulate the market distribution after the position was opened: multiply bins by exp(q/alpha)
    const factorWad = await harness.exposedSafeExp(positionQtyWad.toString(), alphaWad);
    const updatedBinFactors: bigint[] = [WAD, WAD, WAD, WAD].map((b) => mulWadNearest(b, BigInt(factorWad.toString())));
    const updatedTotal = updatedBinFactors.reduce((acc, v) => acc + v, 0n);
    const distributionAfterOpen = mapDistribution({
      totalSum: updatedTotal.toString(),
      binFactors: updatedBinFactors.map((b) => b.toString()),
    });

    // Update harness tree to the same post-open state
    await harness.applyRangeFactor(0, 3, factorWad.toString());

    const position = { lowerTick: 0, upperTick: 4, quantity: positionQty6.toString() };
    const sdkDec = sdkClient.calculateDecreaseProceeds(position, sellQty6.toString(), distributionAfterOpen, market);
    const sdkClose = sdkClient.calculateCloseProceeds(position, distributionAfterOpen, market);

    const proceedsWad = await harness.quoteSell(alphaWad, 0, 3, sellQtyWad.toString());
    const closeWad = await harness.quoteSell(alphaWad, 0, 3, positionQtyWad.toString());

    const proceeds6 = MathUtils.fromWadNearest(new Big(proceedsWad.toString()));
    const close6 = MathUtils.fromWadNearest(new Big(closeWad.toString()));

    const sdkProceeds6 = new Big(sdkDec.proceeds.toString());
    const sdkClose6 = new Big(sdkClose.proceeds.toString());

    const MICRO_TOLERANCE = new Big("1000"); // allow ~0.001 USDC diff for rounding
    expect(proceeds6.minus(sdkProceeds6).abs().lte(MICRO_TOLERANCE), `decrease proceeds mismatch`).to.be.true;
    expect(close6.minus(sdkClose6).abs().lte(MICRO_TOLERANCE), `close proceeds mismatch`).to.be.true;
  });
});

describe("CLMSR v0 parity (safeExp)", () => {
  const v0ArtifactPath = path.resolve(
    __dirname,
    "../../signals-v0/artifacts/contracts/test/CLMSRMathHarness.sol/CLMSRMathHarness.json"
  );
  const v0FixedArtifactPath = path.resolve(
    __dirname,
    "../../signals-v0/artifacts/contracts/libraries/FixedPointMath.sol/FixedPointMathU.json"
  );
  const v0LazyArtifactPath = path.resolve(
    __dirname,
    "../../signals-v0/artifacts/contracts/libraries/LazyMulSegmentTree.sol/LazyMulSegmentTree.json"
  );

  function linkBytecode(
    artifact: { bytecode: string; linkReferences: Record<string, Record<string, { start: number; length: number }[]>> },
    links: Record<string, string>
  ): string {
    let bytecode = artifact.bytecode.replace(/^0x/, "");
    for (const [file, libs] of Object.entries(artifact.linkReferences)) {
      for (const [libName, positions] of Object.entries(libs)) {
        const keyFqn = `${file}:${libName}`;
        const keyShort = libName;
        const address = links[keyFqn] ?? links[keyShort];
        if (!address) {
          throw new Error(`Missing address for library ${keyFqn}`);
        }
        const addrHex = address.replace(/^0x/, "").padStart(40, "0");
        for (const { start, length } of positions) {
          const offset = start * 2; // byte offset -> hex char offset
          bytecode = bytecode.substring(0, offset) + addrHex + bytecode.substring(offset + length * 2);
        }
      }
    }
    return `0x${bytecode}`;
  }

  async function deployV0Harness() {
    const artifact = JSON.parse(fs.readFileSync(v0ArtifactPath, "utf8"));
    const fixedArtifact = JSON.parse(fs.readFileSync(v0FixedArtifactPath, "utf8"));
    const lazyArtifact = JSON.parse(fs.readFileSync(v0LazyArtifactPath, "utf8"));
    const signer = (await ethers.getSigners())[0];

    // deploy v0 libraries from v0 bytecode/abi to ensure selector compatibility
    const fixedFactory = new ContractFactory(fixedArtifact.abi, fixedArtifact.bytecode, signer);
    const fixed = await fixedFactory.deploy();

    // LazyMulSegmentTree bytecode itself has a link reference to FixedPointMathU, so link it first.
    const linkedLazyBytecode = linkBytecode(lazyArtifact, {
      "contracts/libraries/FixedPointMath.sol:FixedPointMathU": fixed.target as string,
      FixedPointMathU: fixed.target as string,
    });
    if (linkedLazyBytecode.includes("__$")) {
      throw new Error("Linked LazyMulSegmentTree bytecode still contains placeholders");
    }
    const lazyFactory = new ContractFactory(lazyArtifact.abi, linkedLazyBytecode, signer);
    const lazy = await lazyFactory.deploy();

    // v0 artifact expects fully-qualified library names from the v0 repo
    //   - contracts/libraries/FixedPointMath.sol:FixedPointMathU
    //   - contracts/libraries/LazyMulSegmentTree.sol:LazyMulSegmentTree
    const linkedBytecode = linkBytecode(artifact, {
      "contracts/libraries/FixedPointMath.sol:FixedPointMathU": fixed.target as string,
      "contracts/libraries/LazyMulSegmentTree.sol:LazyMulSegmentTree": lazy.target as string,
      FixedPointMathU: fixed.target as string,
      LazyMulSegmentTree: lazy.target as string,
    });
    if (linkedBytecode.includes("__$")) {
      throw new Error("Linked bytecode still contains placeholders");
    }
    const linkedFactory = new ContractFactory(artifact.abi, linkedBytecode, signer);
    return linkedFactory.deploy();
  }

  async function deployV1Harness() {
    const lazy = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();
    const Factory = await ethers.getContractFactory("ClmsrMathHarness", {
      libraries: {
        LazyMulSegmentTree: lazy.target,
      },
    });
    return Factory.deploy();
  }

  it("matches v0 exposedSafeExp for representative inputs", async () => {
    if (!fs.existsSync(v0ArtifactPath)) {
      console.warn("v0 artifact missing, skipping v0 parity test");
      return;
    }
    const v0 = await deployV0Harness();
    const v1 = await deployV1Harness();
    const alphas = [ethers.parseEther("0.5"), ethers.parseEther("1"), ethers.parseEther("2")];
    const qs = [ethers.parseEther("0.1"), ethers.parseEther("0.5"), ethers.parseEther("1"), ethers.parseEther("2")];

    for (const a of alphas) {
      for (const q of qs) {
        const v0Val = await v0.exposedSafeExp(q, a);
        const v1Val = await v1.exposedSafeExp(q, a);
        approx(v1Val, v0Val, SAFE_EXP_TOLERANCE);
      }
    }
  });
});
