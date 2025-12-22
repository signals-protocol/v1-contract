import { ethers, upgrades } from "hardhat";
import { expect } from "chai";

describe("Access / Upgrade guards", () => {
  it("prevents re-initialization of SignalsPosition proxy", async () => {
    const [owner] = await ethers.getSigners();
    const positionFactory = await ethers.getContractFactory("SignalsPosition");
    const proxy = await upgrades.deployProxy(positionFactory, [owner.address], { kind: "uups" });
    await proxy.waitForDeployment();

    await expect(proxy.initialize(owner.address)).to.be.revertedWithCustomError(proxy, "InvalidInitialization");
  });

  it("blocks direct module calls (onlyDelegated)", async () => {
    const lazy = await (await ethers.getContractFactory("LazyMulSegmentTree")).deploy();
    const tradeModule = await (
      await ethers.getContractFactory("TradeModule", { libraries: { LazyMulSegmentTree: lazy.target } })
    ).deploy();

    await expect(
      tradeModule.openPosition(1, 0, 1, 1_000, 1)
    ).to.be.revertedWithCustomError(tradeModule, "NotDelegated");
  });

  it("rejects upgrade from non-owner", async () => {
    const [owner, attacker] = await ethers.getSigners();
    const posFactory = await ethers.getContractFactory("SignalsPosition");
    const proxy = await upgrades.deployProxy(posFactory, [owner.address], { kind: "uups" });
    await proxy.waitForDeployment();

    const newImpl = await posFactory.deploy();
    await newImpl.waitForDeployment();
    const upgradeIface = ["function upgradeTo(address)"];
    const proxyAddr = await proxy.getAddress();
    const rogue = new ethers.Contract(proxyAddr, upgradeIface, attacker);
    await expect(rogue.upgradeTo(await newImpl.getAddress())).to.be.reverted;
  });
});
