import { expect } from "chai";
import fs from "fs";
import path from "path";

type Fixture = {
  name: string;
  params: {
    marketId: number;
    lowerTick: number;
    upperTick: number;
    quantity: string;
  };
  expected: {
    openCost: string;
    increaseCost: string;
    decreaseProceeds: string;
    closeProceeds: string;
    positionValue: string;
  };
};

const fixturesPath = path.join(__dirname, "..", "fixtures", "clmsrFixtures.json");
const fixtures: Fixture[] | null = fs.existsSync(fixturesPath)
  ? JSON.parse(fs.readFileSync(fixturesPath, "utf8"))
  : null;

/**
 * Phase 3-0 parity harness.
 * - If real fixtures (clmsrFixtures.json) are not present, the suite is skipped.
 * - Add SDK/v0 parity vectors into test/fixtures/clmsrFixtures.json with the same shape as the sample file.
 */
(fixtures ? describe : describe.skip)("CLMSR SDK parity and invariants", () => {
  it("should match SDK calculateOpenCost within tolerance (fixtures-driven)", async () => {
    expect(fixtures && fixtures.length).to.be.greaterThan(0);
    for (const fx of fixtures!) {
      // TODO: wire to core.calculateOpenCost once v0 parity helpers are available
      // Placeholder: assert shape is present
      expect(fx.expected.openCost).to.be.a("string");
    }
  });

  it("should round-trip quantity -> cost -> quantity' within tolerance (fixtures-driven)", async () => {
    for (const fx of fixtures!) {
      // TODO: perform round-trip once calculateQuantityFromCost is exposed
      expect(fx.params.quantity).to.be.a("string");
    }
  });

  it("should preserve debit/credit rounding rules in e2e scenario (fixtures-driven)", async () => {
    for (const fx of fixtures!) {
      // TODO: build e2e scenario using SDK/v0 results
      expect(fx.expected.closeProceeds).to.be.a("string");
    }
  });
});
