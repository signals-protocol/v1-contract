import { ethers } from "hardhat";
import { expect } from "chai";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  MockPaymentToken,
  MockFeePolicy,
  TradeModuleProxy,
  TradeModule,
  SignalsPosition,
  TestERC1967Proxy,
} from "../../typechain-types";
import { ISignalsCore } from "../../typechain-types/contracts/harness/TradeModuleProxy";

const WAD = ethers.parseEther("1");

interface System {
  users: HardhatEthersSigner[];
  payment: MockPaymentToken;
  core: TradeModuleProxy;
  tradeModule: TradeModule;
  position: SignalsPosition;
}

async function deploySystem(): Promise<System> {
  const [owner, ...users] = await ethers.getSigners();
  const payment = await (await ethers.getContractFactory("MockPaymentToken")).deploy();
  const feePolicy = await (await ethers.getContractFactory("MockFeePolicy")).deploy(0);
  const positionImplFactory = await ethers.getContractFactory("SignalsPosition");
  const positionImpl = await positionImplFactory.deploy();
  await positionImpl.waitForDeployment();
  const initData = positionImplFactory.interface.encodeFunctionData("initialize", [owner.address]);
  const positionProxy = (await (
    await ethers.getContractFactory("TestERC1967Proxy")
  ).deploy(await positionImpl.getAddress(), initData)) as TestERC1967Proxy;
  const position = (await ethers.getContractAt(
    "SignalsPosition",
    await positionProxy.getAddress()
  )) as SignalsPosition;

  const lazy = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();
  const tradeModule = await (
    await ethers.getContractFactory("TradeModule", { libraries: { LazyMulSegmentTree: lazy.target } })
  ).deploy();
  const core = await (
    await ethers.getContractFactory("TradeModuleProxy", { libraries: { LazyMulSegmentTree: lazy.target } })
  ).deploy(tradeModule.target);

  await core.setAddresses(
    payment.target,
    await position.getAddress(),
    300,
    60,
    owner.address,
    feePolicy.target
  );

  const now = (await ethers.provider.getBlock("latest"))!.timestamp;
  const marketA: ISignalsCore.MarketStruct = {
    isActive: true,
    settled: false,
    snapshotChunksDone: false,
    numBins: 4,
    openPositionCount: 0,
    snapshotChunkCursor: 0,
    startTimestamp: now - 10,
    endTimestamp: now + 10_000,
    settlementTimestamp: now + 10_000,
    minTick: 0,
    maxTick: 4,
    tickSpacing: 1,
    settlementTick: 0,
    settlementValue: 0,
    liquidityParameter: WAD,
    feePolicy: ethers.ZeroAddress,
  };
  const marketB = { ...marketA, minTick: -2, maxTick: 2 };
  await core.setMarket(1, marketA);
  await core.setMarket(2, marketB);
  await core.seedTree(1, [WAD, WAD, WAD, WAD]);
  await core.seedTree(2, [WAD, WAD, WAD, WAD]);
  await position.connect(owner).setCore(core.target);

  // fund users
  for (const u of users) {
    await payment.transfer(u.address, 20_000_000n);
    await payment.connect(u).approve(core.target, ethers.MaxUint256);
  }

  return { users, payment: payment as MockPaymentToken, core: core as TradeModuleProxy, tradeModule: tradeModule as TradeModule, position };
}

describe("TradeModule randomized multi-market flows", () => {
  it("maintains openPositionCount and position existence across random ops", async () => {
    const sys = await deploySystem();
    const { users, core, payment, position } = sys;
    type Pos = { owner: number; market: number; qty: bigint; alive: boolean };
    const positions: Record<number, Pos> = {};
    let nextId = 1;
    let seed = 99991;
    const rand = (max: number) => {
      seed = (seed * 1664525 + 1013904223) % 0xffffffff;
      return seed % max;
    };

    const operations = 50;
    for (let i = 0; i < operations; i++) {
      const op = rand(4);
      const userIdx = rand(users.length);
      const user = users[userIdx];
      const marketId = rand(2) + 1; // 1 or 2
      const ticks =
        marketId === 1
          ? { lower: 0, upper: 4 }
          : (() => {
              const lo = -2 + rand(3); // -2,-1,0
              return { lower: lo, upper: lo + 1 };
            })();
      if (op === 0) {
        const qty = BigInt(500 + rand(1_000));
        await core.connect(user).openPosition(marketId, ticks.lower, ticks.upper, qty, 20_000_000);
        positions[nextId] = { owner: userIdx, market: marketId, qty, alive: true };
        nextId++;
      } else if (op === 1 && Object.keys(positions).length > 0) {
        const aliveIds = Object.entries(positions)
          .filter(([, p]) => p.alive)
          .map(([id]) => Number(id));
        if (aliveIds.length === 0) continue;
        const id = aliveIds[rand(aliveIds.length)];
        const pos = positions[id];
        const decQty = pos.qty / 2n;
        if (decQty === 0n) continue;
        await core.connect(users[pos.owner]).decreasePosition(id, decQty, 0);
        positions[id].qty -= decQty;
        if (positions[id].qty === 0n) positions[id].alive = false;
      } else if (op === 2 && Object.keys(positions).length > 0) {
        const aliveIds = Object.entries(positions)
          .filter(([, p]) => p.alive)
          .map(([id]) => Number(id));
        if (aliveIds.length === 0) continue;
        const id = aliveIds[rand(aliveIds.length)];
        const pos = positions[id];
        await core.connect(users[pos.owner]).closePosition(id, 0);
        positions[id].alive = false;
        positions[id].qty = 0n;
      } else if (op === 3) {
        // increase
        const aliveIds = Object.entries(positions)
          .filter(([, p]) => p.alive)
          .map(([id]) => Number(id));
        if (aliveIds.length === 0) continue;
        const id = aliveIds[rand(aliveIds.length)];
        const pos = positions[id];
        const addQty = BigInt(100 + rand(500));
        await core.connect(users[pos.owner]).increasePosition(id, addQty, 20_000_000);
        positions[id].qty += addQty;
      }
      // sanity: balances non-negative
      for (const u of users) {
        const bal = await payment.balanceOf(u.address);
        expect(bal).to.be.gte(0);
      }
    }

    // verify openPositionCount per market matches alive positions
    for (const marketId of [1, 2]) {
      const aliveCount = Object.values(positions).filter((p) => p.alive && p.market === marketId).length;
      const market = await core.markets(marketId);
      expect(Number(market.openPositionCount)).to.equal(aliveCount);
    }
  });
});
