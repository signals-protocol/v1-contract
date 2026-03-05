import { ethers } from "hardhat";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { deployFullSystem, FullSystem } from "../../helpers/fullSystem";
import { uniformFactors } from "../../helpers/constants";
import { buildRedstonePayload, submitWithPayload } from "../../helpers/redstone";
import { deploySeedData } from "../../helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
  SignalsCore,
  SignalsPosition,
  SignalsUSDToken,
  MockFeePolicy,
} from "../../../typechain-types";

describe("E2E: Sponsored Position (openPositionFor)", () => {
  // Shared state
  let system: FullSystem;
  let owner: HardhatEthersSigner;
  let sponsor: HardhatEthersSigner;
  let beneficiary: HardhatEthersSigner;
  let otherUser: HardhatEthersSigner;
  let core: SignalsCore;
  let position: SignalsPosition;
  let payment: SignalsUSDToken;
  let feePolicy: MockFeePolicy;

  const NUM_BINS = 4;
  const ALPHA = ethers.parseEther("1");
  const QUANTITY = 5_000n; // ~$5 worth of shares
  const FUND_AMOUNT = 50_000_000n; // 50 USDC
  const SEED_AMOUNT = 20_000_000n;

  let marketId: bigint;
  let settlement: number;

  async function setupMarket() {
    const now = await time.latest();
    const start = now - 5;
    const end = now + 50;
    settlement = now + 60;

    const baseFactors = uniformFactors(NUM_BINS);
    const seedData = await deploySeedData(baseFactors);

    marketId = await core.createMarket.staticCall(
      0, NUM_BINS, 1, start, end, settlement, NUM_BINS, ALPHA,
      feePolicy.target.toString(), await seedData.getAddress()
    );
    await core.createMarket(
      0, NUM_BINS, 1, start, end, settlement, NUM_BINS, ALPHA,
      feePolicy.target.toString(), await seedData.getAddress()
    );
    await core.seedNextChunks(marketId, NUM_BINS);
  }

  async function settleMarket(tick: number) {
    await time.increaseTo(settlement);
    const payload = await buildRedstonePayload(tick, settlement + 1);
    await submitWithPayload(core, owner, marketId, payload);
    await time.increaseTo(settlement + 6);
    await core.connect(owner).finalizePrimarySettlement(marketId);
  }

  beforeEach(async () => {
    system = await deployFullSystem({ submitWindow: 5, opsWindow: 5 });
    owner = system.owner;
    [sponsor, beneficiary, otherUser] = system.users;
    core = system.core;
    position = system.position;
    payment = system.payment;
    feePolicy = system.feePolicy;

    const coreAddress = await core.getAddress();

    // Seed vault
    await payment.connect(owner).approve(coreAddress, SEED_AMOUNT);
    await core.connect(owner).seedVault(SEED_AMOUNT);

    // Fund sponsor
    await payment.transfer(sponsor.address, FUND_AMOUNT);
    await payment.connect(sponsor).approve(coreAddress, ethers.MaxUint256);

    // Fund other user for regular position tests
    await payment.transfer(otherUser.address, FUND_AMOUNT);
    await payment.connect(otherUser).approve(coreAddress, ethers.MaxUint256);

    // Beneficiary gets no USDC (that's the point — free bet)
    // But needs approval for nothing (no payment from beneficiary)

    await setupMarket();
  });

  // =========================================================
  // Phase 1: openPositionFor
  // =========================================================

  describe("openPositionFor — happy path", () => {
    it("sponsor pays USDC, beneficiary owns NFT", async () => {
      const sponsorBefore = await payment.balanceOf(sponsor.address);
      const beneficiaryBefore = await payment.balanceOf(beneficiary.address);
      const coreBefore = await payment.balanceOf(await core.getAddress());

      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const maxCost = cost + 1_000_000n;

      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, maxCost
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      expect(positions.length).to.equal(1);
      const positionId = positions[0];

      // Beneficiary owns the NFT
      expect(await position.ownerOf(positionId)).to.equal(beneficiary.address);

      // Sponsor paid USDC
      const sponsorAfter = await payment.balanceOf(sponsor.address);
      expect(sponsorBefore - sponsorAfter).to.be.greaterThan(0n);

      // Beneficiary USDC unchanged (still 0)
      expect(await payment.balanceOf(beneficiary.address)).to.equal(beneficiaryBefore);

      // Core received USDC
      const coreAfter = await payment.balanceOf(await core.getAddress());
      expect(coreAfter - coreBefore).to.equal(sponsorBefore - sponsorAfter);
    });

    it("emits PositionOpened with beneficiary as trader (subgraph compat)", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const maxCost = cost + 1_000_000n;

      const tx = await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, maxCost
      );

      // PositionOpened should have beneficiary as trader (delegatecall → event from core address)
      // Use tradeModule ABI attached to core address for event matching
      const tradeModuleAtCore = system.tradeModule.attach(await core.getAddress()) as typeof system.tradeModule;
      await expect(tx).to.emit(tradeModuleAtCore, "PositionOpened");

      // Verify the event args manually
      const receipt = await tx.wait();
      const iface = system.tradeModule.interface;
      const event = receipt!.logs
        .map((log) => { try { return iface.parseLog(log); } catch { return null; } })
        .find((e) => e?.name === "PositionOpened");
      expect(event).to.not.be.undefined;
      expect(event!.args.trader).to.equal(beneficiary.address);
    });

    it("emits PositionSponsored event", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const maxCost = cost + 1_000_000n;

      const tx = await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, maxCost
      );

      // delegatecall events come from core address — use tradeModule ABI
      const tradeModuleAtCore = system.tradeModule.attach(await core.getAddress()) as typeof system.tradeModule;
      await expect(tx).to.emit(tradeModuleAtCore, "PositionSponsored");
    });

    it("stores sponsoredCost and sponsorAddress correctly", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const maxCost = cost + 1_000_000n;

      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, maxCost
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      const positionId = positions[0];

      const sponsoredCost = await core.getSponsoredCost(positionId);
      expect(sponsoredCost).to.be.greaterThan(0n);

      const sponsorAddr = await core.getSponsorAddress(positionId);
      expect(sponsorAddr).to.equal(sponsor.address);
    });
  });

  describe("openPositionFor — revert cases", () => {
    it("reverts if beneficiary is address(0)", async () => {
      await expect(
        core.connect(sponsor).openPositionFor(
          ethers.ZeroAddress, marketId, 1, 3, QUANTITY, 10_000_000n
        )
      ).to.be.revertedWithCustomError(core, "ZeroAddress");
    });

    it("reverts if sponsor has insufficient USDC", async () => {
      // Give beneficiary role to someone with no funds
      const poorSponsor = (await ethers.getSigners())[10];
      const coreAddr = await core.getAddress();
      await payment.connect(poorSponsor).approve(coreAddr, ethers.MaxUint256);

      await expect(
        core.connect(poorSponsor).openPositionFor(
          beneficiary.address, marketId, 1, 3, QUANTITY, 10_000_000n
        )
      ).to.be.reverted;
    });

    it("reverts if sponsor has no approval", async () => {
      const noApproveSponsor = (await ethers.getSigners())[11];
      await payment.transfer(noApproveSponsor.address, FUND_AMOUNT);

      await expect(
        core.connect(noApproveSponsor).openPositionFor(
          beneficiary.address, marketId, 1, 3, QUANTITY, 10_000_000n
        )
      ).to.be.reverted;
    });

    it("reverts if quantity is 0", async () => {
      await expect(
        core.connect(sponsor).openPositionFor(
          beneficiary.address, marketId, 1, 3, 0, 10_000_000n
        )
      ).to.be.revertedWithCustomError(core, "InvalidQuantity");
    });

    it("reverts if maxCost exceeded", async () => {
      await expect(
        core.connect(sponsor).openPositionFor(
          beneficiary.address, marketId, 1, 3, QUANTITY, 1n // absurdly low maxCost
        )
      ).to.be.revertedWithCustomError(core, "CostExceedsMaximum");
    });

    it("reverts when paused", async () => {
      await core.connect(owner).pause();
      await expect(
        core.connect(sponsor).openPositionFor(
          beneficiary.address, marketId, 1, 3, QUANTITY, 10_000_000n
        )
      ).to.be.revertedWithCustomError(core, "EnforcedPause");
    });
  });

  // =========================================================
  // Phase 1: Existing openPosition unchanged
  // =========================================================

  describe("existing openPosition — unchanged behavior", () => {
    it("openPosition: sponsoredCost == 0, sponsorAddress == address(0)", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(otherUser).openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000n);

      const positions = await position.getPositionsByOwner(otherUser.address);
      const positionId = positions[0];

      expect(await core.getSponsoredCost(positionId)).to.equal(0n);
      expect(await core.getSponsorAddress(positionId)).to.equal(ethers.ZeroAddress);
    });
  });

  // =========================================================
  // Phase 2: Sponsored Position — increasePosition blocked
  // =========================================================

  describe("increasePosition — blocked for sponsored positions", () => {
    it("reverts SponsoredPositionCannotIncrease for sponsored position", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      const positionId = positions[0];

      // Fund beneficiary for increase attempt
      await payment.transfer(beneficiary.address, FUND_AMOUNT);
      await payment.connect(beneficiary).approve(await core.getAddress(), ethers.MaxUint256);

      await expect(
        core.connect(beneficiary).increasePosition(positionId, 1_000, 10_000_000n)
      ).to.be.revertedWithCustomError(core, "SponsoredPositionCannotIncrease");
    });

    it("increasePosition still works for regular (non-sponsored) positions", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(otherUser).openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000n);

      const positions = await position.getPositionsByOwner(otherUser.address);
      const positionId = positions[0];

      // Regular position can increase
      await expect(
        core.connect(otherUser).increasePosition(positionId, 1_000, 10_000_000n)
      ).to.not.be.reverted;
    });
  });

  // =========================================================
  // Phase 2: Sponsored Position — closePosition proceeds split
  // =========================================================

  describe("closePosition — sponsored proceeds split", () => {
    let sponsoredPositionId: bigint;

    beforeEach(async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const maxCost = cost + 1_000_000n;

      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, maxCost
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      sponsoredPositionId = positions[0];
    });

    it("profit case: user gets profit, sponsor gets principal back", async () => {
      // Close position (beneficiary must be the caller since they own the NFT)
      const sponsorBefore = await payment.balanceOf(sponsor.address);
      const beneficiaryBefore = await payment.balanceOf(beneficiary.address);

      await core.connect(beneficiary).closePosition(sponsoredPositionId, 0);

      const sponsorAfter = await payment.balanceOf(sponsor.address);
      const beneficiaryAfter = await payment.balanceOf(beneficiary.address);

      const sponsoredCost = await core.getSponsoredCost(sponsoredPositionId);
      // After full close, sponsoredCost should be 0 (all principal accounted for)
      expect(sponsoredCost).to.equal(0n);

      const sponsorReceived = sponsorAfter - sponsorBefore;
      const beneficiaryReceived = beneficiaryAfter - beneficiaryBefore;

      // Total received = proceeds
      const totalReceived = sponsorReceived + beneficiaryReceived;
      expect(totalReceived).to.be.greaterThan(0n);

      // Sponsor receives up to actualCost (principal)
      // Beneficiary receives the remainder (profit or 0)
      // Both should be >= 0
      expect(sponsorReceived).to.be.greaterThanOrEqual(0n);
      expect(beneficiaryReceived).to.be.greaterThanOrEqual(0n);
    });

    it("regular position close: entire proceeds go to user (no split)", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(otherUser).openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000n);

      const positions = await position.getPositionsByOwner(otherUser.address);
      const regularPositionId = positions[0];

      const sponsorBefore = await payment.balanceOf(sponsor.address);
      const userBefore = await payment.balanceOf(otherUser.address);

      await core.connect(otherUser).closePosition(regularPositionId, 0);

      const userAfter = await payment.balanceOf(otherUser.address);
      const sponsorAfter = await payment.balanceOf(sponsor.address);

      // User gets all proceeds
      expect(userAfter - userBefore).to.be.greaterThan(0n);
      // Sponsor balance unchanged
      expect(sponsorAfter).to.equal(sponsorBefore);
    });
  });

  // =========================================================
  // Phase 2: Sponsored Position — decreasePosition (partial close) split
  // =========================================================

  describe("decreasePosition — partial close sponsored split", () => {
    it("50% partial close: proportional principal split", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const maxCost = cost + 1_000_000n;

      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, maxCost
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      const positionId = positions[0];

      const sponsoredCostBefore = await core.getSponsoredCost(positionId);
      expect(sponsoredCostBefore).to.be.greaterThan(0n);

      const halfQuantity = QUANTITY / 2n;

      // Partial close
      await core.connect(beneficiary).decreasePosition(positionId, halfQuantity, 0);

      // Remaining sponsored cost should be ~half
      const sponsoredCostAfter = await core.getSponsoredCost(positionId);
      expect(sponsoredCostAfter).to.be.lessThan(sponsoredCostBefore);

      // Expected: sponsoredCostAfter ≈ sponsoredCostBefore / 2
      // Allow 1 wei rounding tolerance
      const expectedRemaining = (sponsoredCostBefore * halfQuantity) / QUANTITY;
      const remaining = sponsoredCostBefore - expectedRemaining;
      expect(sponsoredCostAfter).to.equal(remaining);
    });

    it("sequential partial closes: cumulative split correct", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      const positionId = positions[0];

      // Close 25%
      const quarter = QUANTITY / 4n;
      await core.connect(beneficiary).decreasePosition(positionId, quarter, 0);

      // Close another 25%
      await core.connect(beneficiary).decreasePosition(positionId, quarter, 0);

      // Close remaining 50%
      await core.connect(beneficiary).closePosition(positionId, 0);

      // Position should be burned
      expect(await position.exists(positionId)).to.equal(false);
    });
  });

  // =========================================================
  // Phase 2: Sponsored Position — claimPayout split
  // =========================================================

  describe("claimPayout — sponsored split", () => {
    it("WIN: user gets profit, sponsor gets principal", async () => {
      // Open sponsored position in winning range (tick 1-3, settle at tick 2)
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      const positionId = positions[0];
      const sponsoredCost = await core.getSponsoredCost(positionId);

      // Settle at tick 2 (winning for range [1,3))
      await settleMarket(2);

      // Wait for claim delay
      await time.increaseTo(settlement + 10);

      const sponsorBefore = await payment.balanceOf(sponsor.address);
      const beneficiaryBefore = await payment.balanceOf(beneficiary.address);

      await core.connect(beneficiary).claimPayout(positionId);

      const sponsorAfter = await payment.balanceOf(sponsor.address);
      const beneficiaryAfter = await payment.balanceOf(beneficiary.address);

      const sponsorReceived = sponsorAfter - sponsorBefore;
      const beneficiaryReceived = beneficiaryAfter - beneficiaryBefore;

      // Payout = QUANTITY (shares) since winning
      const totalPayout = sponsorReceived + beneficiaryReceived;
      expect(totalPayout).to.equal(QUANTITY);

      // Sponsor gets back at most sponsoredCost
      if (totalPayout > sponsoredCost) {
        expect(sponsorReceived).to.equal(sponsoredCost);
        expect(beneficiaryReceived).to.equal(totalPayout - sponsoredCost);
      } else {
        expect(sponsorReceived).to.equal(totalPayout);
        expect(beneficiaryReceived).to.equal(0n);
      }
    });

    it("LOSS: user gets 0, sponsor gets 0", async () => {
      // Open position in range [1,3), settle at tick 0 (losing)
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      const positionId = positions[0];

      // Settle at tick 0 (outside [1,3) → loss)
      await settleMarket(0);

      await time.increaseTo(settlement + 10);

      const sponsorBefore = await payment.balanceOf(sponsor.address);
      const beneficiaryBefore = await payment.balanceOf(beneficiary.address);

      await core.connect(beneficiary).claimPayout(positionId);

      const sponsorAfter = await payment.balanceOf(sponsor.address);
      const beneficiaryAfter = await payment.balanceOf(beneficiary.address);

      // Both get nothing on loss
      expect(sponsorAfter - sponsorBefore).to.equal(0n);
      expect(beneficiaryAfter - beneficiaryBefore).to.equal(0n);
    });

    it("regular position claim: entire payout to user", async () => {
      // Open regular position
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(otherUser).openPosition(marketId, 1, 3, QUANTITY, cost + 1_000_000n);

      const positions = await position.getPositionsByOwner(otherUser.address);
      const positionId = positions[0];

      // Settle at tick 2 (winning)
      await settleMarket(2);
      await time.increaseTo(settlement + 10);

      const userBefore = await payment.balanceOf(otherUser.address);
      const sponsorBefore = await payment.balanceOf(sponsor.address);

      await core.connect(otherUser).claimPayout(positionId);

      const userAfter = await payment.balanceOf(otherUser.address);
      const sponsorAfter = await payment.balanceOf(sponsor.address);

      // User gets full payout
      expect(userAfter - userBefore).to.equal(QUANTITY);
      // Sponsor unchanged
      expect(sponsorAfter).to.equal(sponsorBefore);
    });
  });

  // =========================================================
  // Mixed scenario: sponsored + regular in same market
  // =========================================================

  describe("mixed: sponsored + regular positions coexist", () => {
    it("each position settles independently and correctly", async () => {
      // Sponsored position for beneficiary
      const cost1 = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost1 + 1_000_000n
      );

      // Regular position for otherUser
      const cost2 = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(otherUser).openPosition(marketId, 1, 3, QUANTITY, cost2 + 1_000_000n);

      const sponsoredPositions = await position.getPositionsByOwner(beneficiary.address);
      const regularPositions = await position.getPositionsByOwner(otherUser.address);

      // Settle at tick 2 (winning)
      await settleMarket(2);
      await time.increaseTo(settlement + 10);

      // Claim sponsored
      const sponsorBefore = await payment.balanceOf(sponsor.address);
      const beneficiaryBefore = await payment.balanceOf(beneficiary.address);
      await core.connect(beneficiary).claimPayout(sponsoredPositions[0]);
      const sponsorAfterClaim = await payment.balanceOf(sponsor.address);
      const beneficiaryAfterClaim = await payment.balanceOf(beneficiary.address);

      // Sponsor gets principal back
      expect(sponsorAfterClaim - sponsorBefore).to.be.greaterThan(0n);
      // Beneficiary gets profit
      const beneficiaryProfit = beneficiaryAfterClaim - beneficiaryBefore;
      // Total = QUANTITY
      expect((sponsorAfterClaim - sponsorBefore) + beneficiaryProfit).to.equal(QUANTITY);

      // Claim regular
      const otherUserBefore = await payment.balanceOf(otherUser.address);
      await core.connect(otherUser).claimPayout(regularPositions[0]);
      const otherUserAfter = await payment.balanceOf(otherUser.address);

      // Regular user gets full payout, no split
      expect(otherUserAfter - otherUserBefore).to.equal(QUANTITY);
    });
  });

  // =========================================================
  // Edge cases
  // =========================================================

  describe("edge cases", () => {
    it("multiple sponsors for same beneficiary: each position independent", async () => {
      const anotherSponsor = otherUser;
      // anotherSponsor already funded and approved

      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const maxCost = cost + 1_000_000n;

      // Sponsor A opens for beneficiary
      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 0, 2, QUANTITY, maxCost
      );

      // Sponsor B opens for same beneficiary
      await core.connect(anotherSponsor).openPositionFor(
        beneficiary.address, marketId, 2, 4, QUANTITY, maxCost
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      expect(positions.length).to.equal(2);

      // Each has correct sponsor
      const sponsor1 = await core.getSponsorAddress(positions[0]);
      const sponsor2 = await core.getSponsorAddress(positions[1]);
      expect(sponsor1).to.equal(sponsor.address);
      expect(sponsor2).to.equal(anotherSponsor.address);
    });

    it("sponsor == beneficiary: allowed (functionally a regular position with split)", async () => {
      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      const maxCost = cost + 1_000_000n;

      // Sponsor opens for themselves
      await expect(
        core.connect(sponsor).openPositionFor(
          sponsor.address, marketId, 1, 3, QUANTITY, maxCost
        )
      ).to.not.be.reverted;

      const positions = await position.getPositionsByOwner(sponsor.address);
      const positionId = positions[0];

      // Still recorded as sponsored
      expect(await core.getSponsoredCost(positionId)).to.be.greaterThan(0n);
      expect(await core.getSponsorAddress(positionId)).to.equal(sponsor.address);
    });

    it("beneficiary with 0 USDC can receive sponsored position", async () => {
      expect(await payment.balanceOf(beneficiary.address)).to.equal(0n);

      const cost = await core.calculateOpenCost.staticCall(marketId, 1, 3, QUANTITY);
      await core.connect(sponsor).openPositionFor(
        beneficiary.address, marketId, 1, 3, QUANTITY, cost + 1_000_000n
      );

      const positions = await position.getPositionsByOwner(beneficiary.address);
      expect(positions.length).to.equal(1);
    });
  });
});
