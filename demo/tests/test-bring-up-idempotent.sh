#!/usr/bin/env bash
# Test: second bring-up run changes nothing, completes under 60 seconds (SC-002).
# Requires a ready environment (run bring-up.sh first).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Capture container state before
before=$(podman ps --filter "name=openshell-spiffe-demo" --format '{{.Names}} {{.State}}' | sort)

# Run bring-up and measure time
start_time=$(date +%s)
"${SCRIPT_DIR}/bring-up.sh" >/dev/null 2>&1
end_time=$(date +%s)
elapsed=$((end_time - start_time))

# Capture container state after
after=$(podman ps --filter "name=openshell-spiffe-demo" --format '{{.Names}} {{.State}}' | sort)

# Assert: no state change
if [ "$before" != "$after" ]; then
  echo "FAIL: container state changed on idempotent re-run"
  echo "Before:"
  echo "$before"
  echo "After:"
  echo "$after"
  exit 1
fi

# Assert: under 60 seconds
if [ "$elapsed" -ge 60 ]; then
  echo "FAIL: idempotent re-run took ${elapsed}s (limit: 60s)"
  exit 1
fi

echo "PASS: idempotent re-run completed in ${elapsed}s with no state change"
