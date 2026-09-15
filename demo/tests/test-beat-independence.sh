#!/usr/bin/env bash
# End-to-end test: beat independence (T055, SC-004).
# Every beat must pass when run in reverse order against a ready environment.
# Requires a ready environment with a running sandbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=demo/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=demo/lib/beats.sh
source "${SCRIPT_DIR}/lib/beats.sh"

GATEWAY_ENDPOINT="${GATEWAY_ENDPOINT:-http://127.0.0.1:${PORT_GATEWAY}}"

# Environment not ready is a FAILURE, not a skip (F-10).
# A skip that exits 0 would count as PASS, hiding the fact that the test
# never ran. The caller (verify.sh) decides whether to run e2e tests.
if ! container_is_running "$CONTAINER_GATEWAY" 2>/dev/null; then
  echo "FAIL: environment not ready (gateway not running)"
  exit 1
fi

PASS=0
FAIL=0

# Run beats in reverse order (5, 4, 3, 2, 1)
for i in 5 4 3 2 1; do
  load_beat "$i"

  # Skip inference-dependent beats
  if [ "$BEAT_NEEDS_INFERENCE" = "true" ]; then
    printf "  SKIP  beat %d: %s (needs inference)\n" "$BEAT_ID" "$BEAT_CLAIM"
    continue
  fi

  # Run the curl path (agent-independent)
  if eval "$BEAT_CURL_CMD" >/dev/null 2>&1; then
    if eval "$BEAT_ASSERT" 2>/dev/null; then
      printf "  PASS  beat %d (reverse): %s\n" "$BEAT_ID" "$BEAT_CLAIM"
      PASS=$((PASS + 1))
    else
      printf "  FAIL  beat %d (reverse): assertion failed\n" "$BEAT_ID"
      FAIL=$((FAIL + 1))
    fi
  else
    printf "  FAIL  beat %d (reverse): command failed\n" "$BEAT_ID"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
if [ "$FAIL" -gt 0 ]; then
  printf "%d passed, %d failed\n" "$PASS" "$FAIL"
  exit 1
fi
printf "all %d beat independence checks passed\n" "$PASS"
