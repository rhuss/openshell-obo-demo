#!/usr/bin/env bash
# End-to-end test: inspection surface isolation (T026, FR-013, SC-008).
# The debug surface runs on a UNIX domain socket inside the issuer container,
# so there is no TCP port for the sandbox to reach (C3). This test verifies
# the topological guarantee by attempting the actual attack vector from inside
# the sandbox.
# Requires a ready environment with a running sandbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=demo/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

GATEWAY_ENDPOINT="${GATEWAY_ENDPOINT:-http://127.0.0.1:${PORT_GATEWAY}}"
OS=(openshell --gateway "$GATEWAY_CLI_NAME" --gateway-endpoint "$GATEWAY_ENDPOINT")

# Missing CLI is a test FAILURE, not a skip (C1)
if ! command -v openshell >/dev/null 2>&1; then
  echo "FAIL: openshell CLI not available (required for isolation tests)"
  exit 1
fi

# Missing sandbox is a test FAILURE, not a skip (C1)
if ! "${OS[@]}" sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
  echo "FAIL: sandbox $SANDBOX_NAME does not exist (required for isolation tests)"
  exit 1
fi

PASS=0
FAIL=0

# Assert that a command fails with an EXPECTED failure signal (C1).
# Unlike a bare "did it fail?", this distinguishes a policy denial from a
# CLI error or a down network. The caller provides a grep pattern for the
# expected failure indicator.
assert_expected_failure() {
  local name="$1" expected_pattern="$2"
  shift 2
  local output=""
  local rc=0
  output=$("$@" 2>&1) || rc=$?

  if [ "$rc" -eq 0 ]; then
    printf "  FAIL  %s (command should have failed)\n" "$name"
    FAIL=$((FAIL + 1))
    return
  fi

  # Check the output contains the expected failure signal
  if printf '%s' "$output" | grep -qiE "$expected_pattern"; then
    printf "  PASS  %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s (failed for unexpected reason: %s)\n" "$name" "$output"
    FAIL=$((FAIL + 1))
  fi
}

# C2: Attempt the actual attack vector. Resolve the issuer's demo-network
# alias from inside the sandbox and attempt the debug path on that alias.
# After C3, there is no TCP listener on the debug port (8081), so the
# connection attempt fails topologically, not just by policy.
#
# `--fail-with-body`, not `-f`: the sandbox proxy answers a denied request with
# HTTP 403 and a `{"error":"policy_denied"}` body, and plain `-f` throws that
# body away. Combined with `-s` the command then failed with no output at all,
# so the assertion below could never see why it failed. A policy denial is the
# stronger result than a connection error, so both are accepted.

# Test 1: attempt to reach the debug endpoint via the issuer's network alias
# on the port that USED to serve the debug surface (8081). An escaping agent
# would try exactly this.
assert_expected_failure \
  "debug endpoint unreachable via issuer alias (port 8081)" \
  "policy_denied|not permitted by policy|refused|reset|denied|timed out|couldn't connect|connection.*failed|no route" \
  "${OS[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  curl -s --fail-with-body --max-time 3 "http://${ISSUER_HOST}:8081/debug/last-token"

# Test 2: attempt to reach the debug path on the issuer's main port (8080).
# The main listener does not serve /debug/ paths (returns 404), but even if
# someone added a route, the sandbox policy blocks the issuer host entirely.
assert_expected_failure \
  "debug path on issuer main port blocked" \
  "policy_denied|not permitted by policy|refused|reset|denied|timed out|couldn't connect|connection.*failed|not found|404|no route" \
  "${OS[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  curl -s --fail-with-body --max-time 3 "http://${ISSUER_HOST}:8080/debug/last-token"

# Test 3: no delegated credential in sandbox environment.
# The inner script produces a diagnostic message on both paths so
# assert_expected_failure can match a specific signal (F-11: the old
# pattern "." matched any character, accepting any failure reason).
assert_expected_failure \
  "no delegated credential in sandbox env" \
  "no credential" \
  "${OS[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  bash -c 'if env | grep -qi "bearer\|access_token\|delegation"; then echo "credential found in env"; exit 0; else echo "no credential in env"; exit 1; fi'

echo ""
if [ "$FAIL" -gt 0 ]; then
  printf "%d passed, %d failed\n" "$PASS" "$FAIL"
  exit 1
fi
printf "all %d isolation checks passed\n" "$PASS"
