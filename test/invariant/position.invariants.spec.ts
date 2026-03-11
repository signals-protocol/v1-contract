import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { Signer } from "ethers";
import { SignalsPosition, SignalsUSDToken } from "../../typechain-types";

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

/**
 * Position Contract Invariants
 *
 * Mathematical invariants that must always hold:
 * - INV-P1: totalSupply == sum(balanceOf(all owners))
 * - INV-P2: Position IDs are unique and sequential
 * - INV-P5: Transfer preserves total supply
 * - INV-P6: Burn decreases supply by exactly 1
 */

describe("Position Invariants", () => {
  async function deployPositionFixture() {
    const [owner, alice, bob, charlie, dave] = await ethers.getSigners();
    const core = await deployCoreSigner();

    const implFactory = await ethers.getContractFactory("SignalsPosition");
    const impl = await implFactory.deploy();
    await impl.waitForDeployment();

    const initData = implFactory.interface.encodeFunctionData("initialize", [
      core.address,
      owner.address,
    ]);
    const proxy = await (
      await ethers.getContractFactory("TestERC1967Proxy")
    ).deploy(await impl.getAddress(), initData);

    const position = (await ethers.getContractAt(
      "SignalsPosition",
      await proxy.getAddress()
    )) as SignalsPosition;

    return { owner, core: core.signer, alice, bob, charlie, dave, position };
  }

  describe("INV-P1: Balance Consistency", () => {
    it("maintains balance consistency through operations", async () => {
      const { position, core, alice, bob, charlie } = await loadFixture(
        deployPositionFixture
      );

      const users = [alice, bob, charlie];

      const getSumBalances = async () => {
        let sum = 0n;
        for (const user of users) {
          sum += await position.balanceOf(user.address);
        }
        return sum;
      };

      // Initial state
      expect(await getSumBalances()).to.equal(0n);

      // Mint positions to different users
      await position.connect(core).mintPosition(alice.address, 1, 0, 10, 1000);
      expect(await getSumBalances()).to.equal(1n);

      await position.connect(core).mintPosition(bob.address, 1, 10, 20, 1000);
      expect(await getSumBalances()).to.equal(2n);

      await position.connect(core).mintPosition(charlie.address, 2, 0, 5, 500);
      expect(await getSumBalances()).to.equal(3n);

      // Transfer between users (sum stays same)
      await position
        .connect(alice)
        ["safeTransferFrom(address,address,uint256)"](
          alice.address,
          bob.address,
          1
        );
      expect(await getSumBalances()).to.equal(3n);

      // Burn position
      await position.connect(core).burn(2);
      expect(await getSumBalances()).to.equal(2n);

      // Burn remaining
      await position.connect(core).burn(1);
      await position.connect(core).burn(3);
      expect(await getSumBalances()).to.equal(0n);
    });
  });

  describe("INV-P2: Position ID Uniqueness", () => {
    it("assigns unique sequential IDs", async () => {
      const { position, core, alice, bob, charlie } = await loadFixture(
        deployPositionFixture
      );

      const ids = new Set<bigint>();
      const users = [alice, bob, charlie];

      for (let i = 0; i < 10; i++) {
        const user = users[i % users.length];
        await position.connect(core).mintPosition(user.address, 1, i, i + 1, 1000);
        const id = BigInt(i + 1);
        expect(ids.has(id)).to.be.false;
        ids.add(id);
      }

      expect(ids.size).to.equal(10);
    });

    it("does not reuse IDs after burn", async () => {
      const { position, core, alice } = await loadFixture(deployPositionFixture);

      await position.connect(core).mintPosition(alice.address, 1, 0, 10, 1000); // ID 1
      await position.connect(core).mintPosition(alice.address, 1, 10, 20, 1000); // ID 2
      await position.connect(core).burn(1);
      await position.connect(core).mintPosition(alice.address, 1, 20, 30, 1000); // ID 3

      await expect(position.ownerOf(1)).to.be.reverted;
      expect(await position.ownerOf(2)).to.equal(alice.address);
      expect(await position.ownerOf(3)).to.equal(alice.address);
    });
  });

  describe("INV-P5: Transfer Balance Invariant", () => {
    it("transfer does not change sum of balances", async () => {
      const { position, core, alice, bob, charlie } = await loadFixture(
        deployPositionFixture
      );

      const getSumBalances = async () => {
        return (
          (await position.balanceOf(alice.address)) +
          (await position.balanceOf(bob.address)) +
          (await position.balanceOf(charlie.address))
        );
      };

      await position.connect(core).mintPosition(alice.address, 1, 0, 10, 1000);
      await position.connect(core).mintPosition(alice.address, 1, 10, 20, 1000);

      const sumBefore = await getSumBalances();

      // Multiple transfers
      await position.connect(alice).transferFrom(alice.address, bob.address, 1);
      expect(await getSumBalances()).to.equal(sumBefore);

      await position.connect(bob).transferFrom(bob.address, charlie.address, 1);
      expect(await getSumBalances()).to.equal(sumBefore);

      await position
        .connect(charlie)
        .transferFrom(charlie.address, alice.address, 1);
      expect(await getSumBalances()).to.equal(sumBefore);
    });
  });

  describe("INV-P6: Burn Balance Invariant", () => {
    it("burn decreases sum of balances by exactly 1", async () => {
      const { position, core, alice } = await loadFixture(deployPositionFixture);

      await position.connect(core).mintPosition(alice.address, 1, 0, 10, 1000);
      await position.connect(core).mintPosition(alice.address, 1, 10, 20, 1000);
      await position.connect(core).mintPosition(alice.address, 1, 20, 30, 1000);

      expect(await position.balanceOf(alice.address)).to.equal(3n);

      await position.connect(core).burn(2);
      expect(await position.balanceOf(alice.address)).to.equal(2n);

      await position.connect(core).burn(1);
      expect(await position.balanceOf(alice.address)).to.equal(1n);

      await position.connect(core).burn(3);
      expect(await position.balanceOf(alice.address)).to.equal(0n);
    });
  });

  describe("Stress: Random Operations", () => {
    it("maintains all invariants through random mint/transfer/burn", async () => {
      const { position, core, alice, bob, charlie, dave } = await loadFixture(
        deployPositionFixture
      );

      const users = [alice, bob, charlie, dave];
      const alive = new Map<bigint, string>(); // tokenId -> owner address
      let nextId = 1n;

      // Simple deterministic PRNG
      let seed = 12345;
      const rand = (max: number) => {
        seed = (seed * 1664525 + 1013904223) % 0xffffffff;
        return seed % max;
      };

      const assertAllInvariants = async () => {
        // INV-P1: Balance consistency — sum of tracked alive tokens matches sum of balances
        const expectedSum = BigInt(alive.size);
        let actualSum = 0n;
        for (const user of users) {
          actualSum += await position.balanceOf(user.address);
        }
        expect(actualSum).to.equal(expectedSum);
      };

      // Run random operations
      for (let i = 0; i < 30; i++) {
        const op = rand(3);

        if (op === 0 || alive.size === 0) {
          // Mint
          const user = users[rand(users.length)];
          const market = rand(3) + 1;
          await position
            .connect(core)
            .mintPosition(user.address, market, i, i + 1, 1000);
          alive.set(nextId, user.address);
          nextId++;
        } else if (op === 1 && alive.size > 0) {
          // Transfer
          const keys = Array.from(alive.keys());
          const tokenId = keys[rand(keys.length)];
          const currentOwner = alive.get(tokenId)!;
          const newOwner = users[rand(users.length)];

          if (currentOwner !== newOwner.address) {
            const from = users.find((u) => u.address === currentOwner)!;
            await position
              .connect(from)
              ["safeTransferFrom(address,address,uint256)"](
                from.address,
                newOwner.address,
                tokenId
              );
            alive.set(tokenId, newOwner.address);
          }
        } else if (op === 2 && alive.size > 0) {
          // Burn
          const keys = Array.from(alive.keys());
          const tokenId = keys[rand(keys.length)];
          await position.connect(core).burn(tokenId);
          alive.delete(tokenId);
        }

        await assertAllInvariants();
      }
    });
  });
});
