#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

echo "[1/4] Hardhat numeric invariants"
yarn hardhat test \
  test/unit/lib/lazyMulSegmentTree.spec.ts \
  test/unit/lib/clmsrMath.spec.ts \
  test/invariant/clmsr.invariants.spec.ts

echo "[2/4] Foundry stateful fuzz (numeric kernel)"
(
  cd verification/foundry
  forge test -vv
)

echo "[3/4] Echidna properties (if installed)"
if command -v echidna >/dev/null 2>&1; then
  (
    cd verification/foundry
    echidna . --contract EchidnaLazyMulTree --config echidna.yaml
    echidna . --contract EchidnaFixedPointMath --config echidna-fixedpoint.yaml
    echidna . --contract EchidnaClmsrMath --config echidna-clmsr.yaml
    echidna . --contract EchidnaFeeWaterfallLib --config echidna-feewaterfall.yaml
  )
else
  echo "echidna not found; skipping (install echidna to enable this gate)"
fi

echo "[4/4] SMT check (FixedPointMathU bounded properties)"
"$ROOT_DIR/scripts/verify/smt-fixed-point.sh"

echo "numeric proof pipeline completed"
