#!/usr/bin/env bash
# End-to-end test: binary denial (T047, FR-019).
# Running curl from inside the sandbox to the MCP server must be refused,
# and the deny record must name /usr/bin/curl.
# Requires a ready environment with a running sandbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=demo/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

GATEWAY_ENDPOINT="${GATEWAY_ENDPOINT:-http://127.0.0.1:${PORT_GATEWAY}}"
OS=(openshell --gateway "$GATEWAY_CLI_NAME" --gateway-endpoint "$GATEWAY_ENDPOINT")

# Missing CLI is a test FAILURE, not a skip (C1)
if ! command -v openshell >/dev/null 2>&1; then
  echo "FAIL: openshell CLI not available (required for binary denial tests)"
  exit 1
fi

# Missing sandbox is a test FAILURE, not a skip (C1)
if ! "${OS[@]}" sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
  echo "FAIL: sandbox $SANDBOX_NAME does not exist (required for binary denial tests)"
  exit 1
fi

# Attempt to reach the MCP server with curl from inside the sandbox.
# This must fail because /usr/bin/curl is not in the policy binaries list.
#
# `--fail-with-body`, not `-f`: the proxy answers with HTTP 403 and a
# `{"error":"policy_denied"}` body, which plain `-f` discards.
output=""
if output=$("${OS[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    curl -s --fail-with-body --max-time 5 "http://${MCP_HOST}:8080/" 2>&1); then
  echo "FAIL: curl from sandbox to MCP server should have been refused"
  echo "Output: $output"
  exit 1
fi

if ! echo "$output" | grep -qE "policy_denied|not permitted by policy"; then
  echo "FAIL: curl failed, but not with a policy denial"
  echo "Output: $output"
  exit 1
fi

# The binary name is in the gateway's deny record, not in the HTTP response the
# sandbox sees: the proxy deliberately tells the caller nothing about why. So
# read it back from the audit trail rather than from curl's own output.
record=$("${OS[@]}" logs "$SANDBOX_NAME" -n 200 --source sandbox 2>/dev/null \
  | grep -F "DENIED" | grep -F "/usr/bin/curl" | grep -F "$MCP_HOST" | tail -1)

if [ -n "$record" ]; then
  echo "PASS: curl denied with record naming /usr/bin/curl"
  echo "Record: $record"
else
  echo "FAIL: no deny record naming /usr/bin/curl for $MCP_HOST"
  echo "Output: $output"
  exit 1
fi
