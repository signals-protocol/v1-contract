/**
 * Fee Waterfall Reference Implementation (TypeScript)
 *
 * Pure TypeScript implementation of whitepaper Sec 4.3-4.6
 * Used to verify on-chain FeeWaterfallLib matches expected behavior.
 */

const WAD = 10n ** 18n;

export interface FeeWaterfallParams {
  Lt: bigint; // P&L (signed)
  Ftot: bigint; // Total gross fees
  Nprev: bigint; // Previous NAV
  Bprev: bigint; // Previous Backstop NAV
  Tprev: bigint; // Previous Treasury NAV
  deltaEt: bigint; // Available backstop support
  pdd: bigint; // Drawdown floor (negative, WAD)
  rhoBS: bigint; // Backstop coverage ratio (WAD)
  phiLP: bigint; // LP fee share (WAD)
  phiBS: bigint; // Backstop fee share (WAD)
  phiTR: bigint; // Treasury fee share (WAD)
}

export interface FeeWaterfallResult {
  // Intermediate values
  Floss: bigint;
  Fpool: bigint;
  Nraw: bigint;
  Gt: bigint;
  Ffill: bigint;
  Fdust: bigint;

  // Output values
  Ft: bigint;
  Npre: bigint;
  Bnext: bigint;
  Tnext: bigint;
}

function wMul(a: bigint, b: bigint): bigint {
  return (a * b) / WAD;
}

/**
 * WAD multiply with round-up (ceil)
 * Per whitepaper v2: ceil semantics required for Nfloor calculation
 * to ensure grantNeed is never under-estimated (drawdown floor is invariant)
 */
function wMulUp(a: bigint, b: bigint): bigint {
  const product = a * b;
  return product === 0n ? 0n : (product - 1n) / WAD + 1n;
}

function min(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

export function calculateFeeWaterfall(
  p: FeeWaterfallParams
): FeeWaterfallResult {
  // Validate inputs
  // pdd must be in range (-WAD, 0)
  if (p.pdd >= 0n || p.pdd < -WAD) {
    throw new Error(`InvalidDrawdownFloor: pdd=${p.pdd} must be in (-WAD, 0)`);
  }

  const phiSum = p.phiLP + p.phiBS + p.phiTR;
  if (phiSum !== WAD) {
    throw new Error(`InvalidPhiSum: ${phiSum} != ${WAD}`);
  }

  // ========================================
  // Step 1: Loss Compensation
  // ========================================
  const Lneg = p.Lt < 0n ? -p.Lt : 0n;
  const Floss = min(p.Ftot, Lneg);
  const Fpool = p.Ftot - Floss;

  // Nraw = Nprev + Lt + Floss
  let Nraw: bigint;
  if (p.Lt >= 0n) {
    Nraw = p.Nprev + p.Lt + Floss;
  } else {
    const loss = -p.Lt;
    const temp = p.Nprev + Floss;
    if (temp < loss) {
      throw new Error(`CatastrophicLoss: loss=${loss}, navPlusFloss=${temp}`);
    }
    Nraw = temp - loss;
  }

  // ========================================
  // Step 2: Drawdown Floor & Grant
  // ========================================
  // Per whitepaper v2: "G^need_t := max{0, ⌈G^min_t⌉}" requires ceil semantics
  // We use wMulUp for Nfloor to ensure conservative (higher) floor calculation
  // This guarantees grantNeed is never under-estimated (drawdown floor is invariant)
  let Nfloor: bigint;
  if (p.Nprev > 0n) {
    const wadPlusPdd = WAD + p.pdd;
    // Use wMulUp (ceil) to ensure Nfloor is conservatively high
    Nfloor = wadPlusPdd > 0n ? wMulUp(p.Nprev, wadPlusPdd) : 0n;
  } else {
    Nfloor = 0n;
  }

  const grantNeed = Nfloor > Nraw ? Nfloor - Nraw : 0n;

  // WP v2: if grantNeed > deltaEt, batch must revert (drawdown floor invariant)
  if (grantNeed > p.deltaEt) {
    throw new Error(
      `GrantExceedsTailBudget: grantNeed=${grantNeed}, deltaEt=${p.deltaEt}`
    );
  }

  // Gt = grantNeed (no capping - either we can afford it or we revert)
  const Gt = grantNeed;

  if (Gt > p.Bprev) {
    throw new Error(
      `InsufficientBackstopForGrant: required=${Gt}, available=${p.Bprev}`
    );
  }

  const Ngrant = Nraw + Gt;
  const Bgrant = p.Bprev - Gt;

  // ========================================
  // Step 3: Backstop Coverage Target
  // ========================================
  const Btarget = wMul(p.rhoBS, Ngrant);
  const dBneed = Btarget > Bgrant ? Btarget - Bgrant : 0n;
  const Ffill = min(dBneed, Fpool);
  const Fremain = Fpool - Ffill;

  // ========================================
  // Step 4: Residual Split
  // ========================================
  const FcoreLP = wMul(Fremain, p.phiLP);
  const FcoreBS = wMul(Fremain, p.phiBS);
  const FcoreTR = wMul(Fremain, p.phiTR);
  const Fdust = Fremain - FcoreLP - FcoreBS - FcoreTR;

  // ========================================
  // Step 5: Final Output Values
  // ========================================
  const Ft = Floss + FcoreLP + Fdust;
  const Npre = Ngrant + FcoreLP;
  const Bnext = Bgrant + Ffill + FcoreBS;
  const Tnext = p.Tprev + FcoreTR;

  return {
    Floss,
    Fpool,
    Nraw,
    Gt,
    Ffill,
    Fdust,
    Ft,
    Npre,
    Bnext,
    Tnext,
  };
}

/**
 * Generate random parameters for fuzz testing
 */
export function generateRandomParams(): FeeWaterfallParams {
  const rand = () => (BigInt(Math.floor(Math.random() * 1000)) * WAD) / 1000n;
  const randNav = () => BigInt(Math.floor(Math.random() * 10000) + 100) * WAD;

  // Random P&L between -500 and +500
  const Lt = BigInt(Math.floor(Math.random() * 1000) - 500) * WAD;

  return {
    Lt,
    Ftot: rand() * 100n,
    Nprev: randNav(),
    Bprev: randNav() / 5n, // ~20% of NAV
    Tprev: randNav() / 20n, // ~5% of NAV
    deltaEt: randNav() / 10n,
    pdd: -300000000000000000n, // -0.3 (30% drawdown floor)
    rhoBS: 200000000000000000n, // 0.2 (20% coverage)
    phiLP: 700000000000000000n, // 0.7
    phiBS: 200000000000000000n, // 0.2
    phiTR: 100000000000000000n, // 0.1
  };
}
