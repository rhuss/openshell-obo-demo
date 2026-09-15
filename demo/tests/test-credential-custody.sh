#!/usr/bin/env bash
# End-to-end test: credential custody (T050, FR-022).
# The sandbox environment must hold an openshell:resolve:env: placeholder,
# and that value must fail to authenticate against the inference service.
# Requires a ready environment with a running sandbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=demo/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

GATEWAY_ENDPOINT="${GATEWAY_ENDPOINT:-http://127.0.0.1:${PORT_GATEWAY}}"
OS=(openshell --gateway "$GATEWAY_CLI_NAME" --gateway-endpoint "$GATEWAY_ENDPOINT")

# Missing CLI is a test FAILURE, not a skip (C1)
if ! command -v openshell >/dev/null 2>&1; then
  echo "FAIL: openshell CLI not available (required for custody tests)"
  exit 1
fi

# Missing sandbox is a test FAILURE, not a skip (C1)
if ! "${OS[@]}" sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
  echo "FAIL: sandbox $SANDBOX_NAME does not exist (required for custody tests)"
  exit 1
fi

PASS=0
FAIL=0
INCONCLUSIVE=0

# Check that the sandbox env holds an openshell:resolve:env: placeholder
env_output=""
env_output=$("${OS[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
  env 2>/dev/null) || true

if echo "$env_output" | grep -q "openshell:resolve:env:"; then
  printf "  PASS  sandbox holds openshell:resolve:env: placeholder\n"
  PASS=$((PASS + 1))

  # Extract the placeholder value
  placeholder=$(echo "$env_output" | grep "openshell:resolve:env:" | head -1 | cut -d= -f2)

  # C4: Distinguish network failure from auth rejection.
  # Capture the HTTP status code (matching the pattern in beats.sh:261-276).
  # A venue network blocking HTTPS must be reported as INCONCLUSIVE, never PASS.
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "x-api-key: ${placeholder}" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-sonnet-4-20250514","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
    "https://api.anthropic.com/v1/messages" 2>/dev/null) || http_code="000"

  case "$http_code" in
    000)
      # Network unreachable: cannot verify the security assertion (C4)
      printf "  INCONCLUSIVE  placeholder auth test: network unreachable (HTTP 000)\n"
      printf "                Cannot verify credential rejection from this venue.\n"
      INCONCLUSIVE=$((INCONCLUSIVE + 1))
      ;;
    200)
      # The placeholder authenticated. This should never happen.
      printf "  FAIL  placeholder authenticated successfully (should be worthless)\n"
      FAIL=$((FAIL + 1))
      ;;
    401|403)
      # Credential rejected. This is the expected outcome.
      printf "  PASS  placeholder rejected by inference service (HTTP %s)\n" "$http_code"
      PASS=$((PASS + 1))
      ;;
    *)
      # Any other HTTP code is unexpected and inconclusive
      printf "  INCONCLUSIVE  placeholder auth test: unexpected HTTP %s\n" "$http_code"
      INCONCLUSIVE=$((INCONCLUSIVE + 1))
      ;;
  esac
else
  printf "  FAIL  no openshell:resolve:env: placeholder in sandbox env\n"
  FAIL=$((FAIL + 1))
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  printf "%d passed, %d failed, %d inconclusive\n" "$PASS" "$FAIL" "$INCONCLUSIVE"
  exit 1
fi
if [ "$INCONCLUSIVE" -gt 0 ]; then
  printf "%d passed, %d inconclusive (network unreachable, cannot verify)\n" "$PASS" "$INCONCLUSIVE"
  # Inconclusive is NOT a pass. Exit non-zero so verify.sh does not count it
  # as a passing security assertion (C4).
  exit 2
fi
printf "all %d custody checks passed\n" "$PASS"
