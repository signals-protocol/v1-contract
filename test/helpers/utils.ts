import { expect } from "chai";
import { BigNumberish } from "ethers";

/**
 * Convert BigNumberish to bigint
 */
export function toBN(value: BigNumberish): bigint {
  return BigInt(value.toString());
}

/**
 * Assert two values are approximately equal within tolerance
 */
export function approx(
  actual: BigNumberish,
  expected: BigNumberish,
  tolerance: BigNumberish
): void {
  const a = toBN(actual);
  const e = toBN(expected);
  const t = toBN(tolerance);
  const diff = a >= e ? a - e : e - a;
  expect(
    diff <= t,
    `expected ${a.toString()} ≈ ${e.toString()} (diff ${diff.toString()}, tol ${t.toString()})`
  ).to.be.true;
}

/**
 * Assert value is within a percentage of expected
 */
export function approxPercent(
  actual: BigNumberish,
  expected: BigNumberish,
  percentTolerance: number
): void {
  const a = toBN(actual);
  const e = toBN(expected);
  const diff = a >= e ? a - e : e - a;
  const tolerance = (e * BigInt(Math.floor(percentTolerance * 100))) / 10000n;
  expect(
    diff <= tolerance,
    `expected ${a.toString()} ≈ ${e.toString()} within ${percentTolerance}% (diff ${diff.toString()})`
  ).to.be.true;
}

/**
 * Deterministic PRNG for reproducible fuzz tests
 */
export function createPrng(seed: bigint = 0x6eed0e9dafbb99b5n) {
  let state = seed & ((1n << 64n) - 1n);
  const modulus = 1n << 64n;
  const multiplier = 6364136223846793005n;
  const increment = 1442695040888963407n;

  return {
    next(): bigint {
      state = (state * multiplier + increment) % modulus;
      return state;
    },
    nextInt(maxExclusive: number): number {
      if (maxExclusive <= 0) {
        throw new Error("maxExclusive must be positive");
      }
      return Number(this.next() % BigInt(maxExclusive));
    },
    nextBigInt(maxExclusive: bigint): bigint {
      if (maxExclusive <= 0n) {
        throw new Error("maxExclusive must be positive");
      }
      return this.next() % maxExclusive;
    },
    nextInRange(min: bigint, max: bigint): bigint {
      if (min >= max) {
        throw new Error("min must be less than max");
      }
      return min + this.nextBigInt(max - min);
    },
  };
}

/**
 * Generate array of random factors within bounds
 */
export function randomFactors(
  prng: ReturnType<typeof createPrng>,
  count: number,
  minFactor: bigint,
  maxFactor: bigint
): bigint[] {
  return Array.from({ length: count }, () =>
    prng.nextInRange(minFactor, maxFactor)
  );
}




