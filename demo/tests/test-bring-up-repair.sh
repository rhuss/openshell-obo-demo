#!/usr/bin/env bash
# Test: a stopped component is restarted, not duplicated (FR-002).
# Requires a ready environment (run bring-up.sh first).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Count containers before
count_before=$(podman ps --filter "name=openshell-spiffe-demo" --format '{{.Names}}' | wc -l | tr -d ' ')

# Stop one component
podman stop "$CONTAINER_ISSUER" >/dev/null 2>&1 || true

# Verify it is stopped
if container_is_running "$CONTAINER_ISSUER"; then
  echo "FAIL: container was not actually stopped"
  exit 1
fi

# Run bring-up to repair
"${SCRIPT_DIR}/bring-up.sh" >/dev/null 2>&1

# Verify it is running again
if ! container_is_running "$CONTAINER_ISSUER"; then
  echo "FAIL: stopped container was not restarted by bring-up"
  exit 1
fi

# Verify no duplicate containers
count_after=$(podman ps --filter "name=openshell-spiffe-demo" --format '{{.Names}}' | wc -l | tr -d ' ')
if [ "$count_after" -gt "$count_before" ]; then
  echo "FAIL: bring-up created duplicate containers ($count_before -> $count_after)"
  exit 1
fi

echo "PASS: stopped component repaired without duplication"
