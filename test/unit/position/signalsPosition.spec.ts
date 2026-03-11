import { ethers } from "hardhat";
import { expect } from "chai";
import { Signer } from "ethers";
import { SignalsPosition, SignalsUSDToken, TestERC1967Proxy } from "../../../typechain-types";

async function deployCoreSigner(): Promise<{ address: string; signer: Signer }> {
  const token = (await (
    await ethers.getContractFactory("SignalsUSDToken")
  ).deploy()) as SignalsUSDToken;
  await token.waitForDeployment();
  const address = await token.getAddress();
  await ethers.provider.send("hardhat_impersonateAccount", [address]);
  await ethers.provider.send("hardhat_setBalance", [
    address,
    ethers.toBeHex(ethers.parseEther("10")),
  ]);
  const signer = await ethers.getSigner(address);
  return { address, signer };
}

async function deployPosition(
  initialCore: string,
  ownerSafe: string
): Promise<SignalsPosition> {
  const implFactory = await ethers.getContractFactory("SignalsPosition");
  const impl = await implFactory.deploy();
  await impl.waitForDeployment();
  const initData = implFactory.interface.encodeFunctionData("initialize", [
    initialCore,
    ownerSafe,
  ]);
  const proxy = (await (
    await ethers.getContractFactory("TestERC1967Proxy")
  ).deploy(await impl.getAddress(), initData)) as TestERC1967Proxy;
  return (await ethers.getContractAt(
    "SignalsPosition",
    await proxy.getAddress()
  )) as SignalsPosition;
}

async function deployPositionFixture() {
  const [owner, user, alice, bob, carol] = await ethers.getSigners();
  const core = await deployCoreSigner();
  const position = await deployPosition(core.address, owner.address);
  return { position, core: core.signer, owner, user, alice, bob, carol };
}

describe("SignalsPosition", () => {
  it("enforces core-only mint/burn/update", async () => {
    const { position, core, user } = await deployPositionFixture();

    await expect(
      position.connect(user).mintPosition(user.address, 1, 0, 1, 1_000)
    )
      .to.be.revertedWithCustomError(position, "UnauthorizedCaller")
      .withArgs(user.address);

    await position.connect(core).mintPosition(user.address, 1, 0, 1, 1_000);
    await expect(
      position.connect(core).updateQuantity(1, 0)
    ).to.be.revertedWithCustomError(position, "InvalidQuantity");
    await position.connect(core).updateQuantity(1, 2_000);

    await expect(position.connect(user).burn(1)).to.be.revertedWithCustomError(
      position,
      "UnauthorizedCaller"
    );
    await position.connect(core).burn(1);
    await expect(position.getPosition(1)).to.be.revertedWithCustomError(
      position,
      "PositionNotFound"
    );
  });

  // ============================================================
  // Edge Cases: Range Validation
  // ============================================================
  describe("Edge Cases: Range Validation", () => {
    it("reverts burn on non-existent position", async () => {
      const { position, core } = await deployPositionFixture();

      // Burn non-existent position (ID 999)
      await expect(position.connect(core).burn(999)).to.be.reverted;
    });

    it("reverts double burn", async () => {
      const { position, core, user } = await deployPositionFixture();

      await position.connect(core).mintPosition(user.address, 1, 0, 1, 1_000);
      await position.connect(core).burn(1);

      // Double burn should fail
      await expect(position.connect(core).burn(1)).to.be.reverted;
    });

    it("handles maximum quantity value", async () => {
      const { position, core, user } = await deployPositionFixture();

      // Max uint128 quantity
      const maxQty = 2n ** 128n - 1n;
      await position.connect(core).mintPosition(user.address, 1, 0, 1, maxQty);

      const pos = await position.getPosition(1);
      expect(pos.quantity).to.equal(maxQty);
    });

    it("handles zero-based tick ranges", async () => {
      const { position, core, user } = await deployPositionFixture();

      // Mint at [0, 1) range
      await position.connect(core).mintPosition(user.address, 1, 0, 1, 1_000);
      const pos = await position.getPosition(1);
      expect(pos.lowerTick).to.equal(0);
      expect(pos.upperTick).to.equal(1);
    });
  });

});
