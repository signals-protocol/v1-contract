import { ethers } from "hardhat";

/**
 * Deploy FixedPointMathTest harness
 */
export async function deployFixedPointMathTest() {
  const Factory = await ethers.getContractFactory("FixedPointMathTest");
  const test = await Factory.deploy();
  await test.waitForDeployment();
  return test;
}

/**
 * Deploy LazyMulSegmentTreeTest harness with library linking
 */
export async function deployLazyMulSegmentTreeTest() {
  // LazyMulSegmentTreeTest uses LazyMulSegmentTree library
  const lazyLib = await (
    await ethers.getContractFactory("LazyMulSegmentTree")
  ).deploy();

  const Factory = await ethers.getContractFactory("LazyMulSegmentTreeTest", {
    libraries: {
      LazyMulSegmentTree: lazyLib.target,
    },
  });
  const test = await Factory.deploy();
  await test.waitForDeployment();
  return test;
}

/**
 * Deploy ClmsrMathHarness with LazyMulSegmentTree library
 */
export async function deployClmsrMathHarness() {
  const lazyLib = await (
    await ethers.getContractFactory("LazyMulSegmentTree")
  ).deploy();

  const Factory = await ethers.getContractFactory("ClmsrMathHarness", {
    libraries: {
      LazyMulSegmentTree: lazyLib.target,
    },
  });
  const harness = await Factory.deploy();
  await harness.waitForDeployment();
  return harness;
}

/**
 * Deploy full trade module test environment
 */
export async function deployTradeModuleTestEnv() {
  const [owner, user] = await ethers.getSigners();

  const payment = await (
    await ethers.getContractFactory("MockPaymentToken")
  ).deploy();

  const positionImplFactory = await ethers.getContractFactory("SignalsPosition");
  const positionImpl = await positionImplFactory.deploy();
  await positionImpl.waitForDeployment();
  const positionInit = positionImplFactory.interface.encodeFunctionData(
    "initialize",
    [owner.address]
  );
  const positionProxy = await (
    await ethers.getContractFactory("TestERC1967Proxy")
  ).deploy(positionImpl.target, positionInit);
  const position = await ethers.getContractAt(
    "SignalsPosition",
    await positionProxy.getAddress()
  );

  const feePolicy = await (
    await ethers.getContractFactory("MockFeePolicy")
  ).deploy(0);

  const lazyLib = await (
    await ethers.getContractFactory("LazyMulSegmentTree")
  ).deploy();

  const tradeModule = await (
    await ethers.getContractFactory("TradeModule", {
      libraries: { LazyMulSegmentTree: lazyLib.target },
    })
  ).deploy();

  const core = await (
    await ethers.getContractFactory("TradeModuleProxy", {
      libraries: { LazyMulSegmentTree: lazyLib.target },
    })
  ).deploy(tradeModule.target);

  return { owner, user, payment, position, feePolicy, core, lazyLib };
}

