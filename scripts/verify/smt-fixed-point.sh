#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

solc contracts/testonly/smt/FixedPointCoreSMT.sol \
  --base-path . \
  --include-path node_modules \
  --allow-paths . \
  --model-checker-engine chc \
  --model-checker-targets assert \
  --model-checker-contracts contracts/testonly/smt/FixedPointCoreSMT.sol:FixedPointCoreSMT \
  --model-checker-timeout 20000 \
  >/tmp/fixed_point_smt.out

if grep -q "Assertion violation" /tmp/fixed_point_smt.out; then
  cat /tmp/fixed_point_smt.out
  echo "SMT check failed"
  exit 1
fi

echo "SMT check completed (no assertion violation reported)"
