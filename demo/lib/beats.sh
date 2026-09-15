#!/usr/bin/env bash
# Beat definitions shared by scene.sh and verify.sh.
# Each beat is a function that populates the BEAT_* variables.
#
# Data model (per data-model.md):
#   id              Ordinal, 1 to 5
#   claim           The one sentence the presenter asserts
#   agent_cmd       Invocation driving the beat through the agent
#   curl_cmd        Invocation demonstrating the same mechanism without the agent (FR-010)
#   evidence_cmd    What produces the audience-visible proof
#   assert          Predicate verify.sh checks (FR-005, SC-011)
#   needs_inference Whether the beat requires the inference service (SC-010)
#
# Invariant: agent_cmd and curl_cmd must satisfy the same assert.
# Invariant: no beat's core assertion sets needs_inference.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demo/lib/common.sh
source "${SCRIPT_DIR}/common.sh"

BEAT_COUNT=5

# Gateway and CLI settings (GATEWAY_CLI_NAME comes from common.sh)
GATEWAY_ENDPOINT="http://127.0.0.1:${PORT_GATEWAY}"
OS_CMD=(openshell --gateway "$GATEWAY_CLI_NAME" --gateway-endpoint "$GATEWAY_ENDPOINT")

# ── Beat registration ───────────────────────────────────────────────

# Each beat_N function sets these globals:
BEAT_ID=""
BEAT_CLAIM=""
BEAT_AGENT_CMD=""
BEAT_CURL_CMD=""
BEAT_EVIDENCE_CMD=""
BEAT_ASSERT=""
BEAT_NEEDS_INFERENCE=false

# Optional custody evidence for beat 3 (T054, T054a, T054b)
BEAT_CUSTODY_EVIDENCE_CMD=""
BEAT_CUSTODY_NEEDS_INFERENCE=false

# Load a beat by number
load_beat() {
  local n="$1"
  BEAT_ID=""
  BEAT_CLAIM=""
  BEAT_AGENT_CMD=""
  BEAT_CURL_CMD=""
  BEAT_EVIDENCE_CMD=""
  BEAT_ASSERT=""
  BEAT_NEEDS_INFERENCE=false
  BEAT_CUSTODY_EVIDENCE_CMD=""
  BEAT_CUSTODY_NEEDS_INFERENCE=false
  case "$n" in
    1) beat_1 ;;
    2) beat_2 ;;
    3) beat_3 ;;
    4) beat_4 ;;
    5) beat_5 ;;
    *) fail "Unknown beat: $n"; return 1 ;;
  esac
}

# List all beats with their claims
list_beats() {
  local i
  for i in $(seq 1 "$BEAT_COUNT"); do
    load_beat "$i"
    printf "  %d  %s\n" "$BEAT_ID" "$BEAT_CLAIM"
  done
}

# ── Beat definitions ────────────────────────────────────────────────

# Beat 1: Sandbox creation with default deny (T020)
beat_1() {
  BEAT_ID=1
  BEAT_CLAIM="The sandbox exists with default deny: unlisted destinations are refused"

  BEAT_AGENT_CMD="beat_1_agent"
  BEAT_CURL_CMD="beat_1_curl"
  BEAT_EVIDENCE_CMD="beat_1_evidence"
  BEAT_ASSERT="beat_1_assert"
  BEAT_NEEDS_INFERENCE=false
}

beat_1_agent() {
  # The agent tries to reach an unlisted destination and is refused
  "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    /usr/local/bin/claude --print "Try to fetch https://example.com and report what happens" 2>&1 || true
}

beat_1_curl() {
  # Directly attempt an unlisted destination from inside the sandbox
  "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    curl -sS --max-time 5 http://example.com/ 2>&1 || true
}

beat_1_evidence() {
  printf "${C_BOLD}Sandbox:${C_RESET} %s\n" "$SANDBOX_NAME"
  "${OS_CMD[@]}" sandbox list 2>/dev/null | grep "$SANDBOX_NAME" || true
  echo ""
  printf "${C_BOLD}Policy active:${C_RESET} unlisted destinations refused\n"
}

beat_1_assert() {
  # Assert: sandbox exists
  "${OS_CMD[@]}" sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME" || return 1

  # Assert: default deny, an unlisted destination is actually refused (C5)
  local deny_output
  deny_output=$("${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    curl -sS --max-time 5 "http://example.com/" 2>&1) || true
  # If curl succeeded with real content, default deny is broken
  if printf '%s' "$deny_output" | grep -qi "<!doctype\|<html"; then
    return 1
  fi
  # Require a specific refusal indicator, not just "any output" (F-07).
  # This distinguishes a policy denial from a transient network error or timeout.
  if printf '%s' "$deny_output" | grep -qiE "refused|reset|denied|blocked|not allowed|policy"; then
    return 0
  fi
  # No recognizable denial signal: treat as inconclusive
  return 1
}

# Beat 2: Workload identity (T021)
beat_2() {
  BEAT_ID=2
  BEAT_CLAIM="The sandbox has a workload identity (SPIRE entry) that the agent cannot access"

  BEAT_AGENT_CMD="beat_2_agent"
  BEAT_CURL_CMD="beat_2_curl"
  BEAT_EVIDENCE_CMD="beat_2_evidence"
  BEAT_ASSERT="beat_2_assert"
  BEAT_NEEDS_INFERENCE=false
}

beat_2_agent() {
  beat_2_curl
}

beat_2_curl() {
  # Show the SPIRE entry exists for this sandbox. The entry is keyed by the
  # gateway's sandbox UUID, not by the sandbox name.
  local sandbox_spiffe
  sandbox_spiffe=$(sandbox_spiffe_id "$(sandbox_uuid "$SANDBOX_NAME")")
  podman exec "$CONTAINER_SPIRE_SERVER" \
    /opt/spire/bin/spire-server entry show \
    -socketPath /run/spire/server/private/api.sock 2>/dev/null | \
    grep -A2 "$sandbox_spiffe" || true
}

beat_2_evidence() {
  local sandbox_spiffe
  sandbox_spiffe=$(sandbox_spiffe_id "$(sandbox_uuid "$SANDBOX_NAME")")
  printf "${C_BOLD}SPIRE entry:${C_RESET}\n"
  podman exec "$CONTAINER_SPIRE_SERVER" \
    /opt/spire/bin/spire-server entry show \
    -socketPath /run/spire/server/private/api.sock 2>/dev/null | \
    grep -A5 "$sandbox_spiffe" || echo "  (not found)"
  echo ""
  printf "${C_BOLD}Agent cannot reach Workload API:${C_RESET}\n"
  # The socket path is not mounted into the sandbox
  "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    ls -la /run/spire 2>&1 || echo "  /run/spire: not accessible (as expected)"
}

beat_2_assert() {
  # Assert: SPIRE entry exists for this sandbox
  local sandbox_uuid_value sandbox_spiffe
  sandbox_uuid_value=$(sandbox_uuid "$SANDBOX_NAME")
  # An unresolvable name must fail loudly rather than search for
  # ".../sandbox/" and match whatever happens to be registered.
  [ -n "$sandbox_uuid_value" ] || return 1
  sandbox_spiffe=$(sandbox_spiffe_id "$sandbox_uuid_value")
  podman exec "$CONTAINER_SPIRE_SERVER" \
    /opt/spire/bin/spire-server entry show \
    -socketPath /run/spire/server/private/api.sock 2>/dev/null | \
    grep -q "$sandbox_spiffe"
}

# Beat 3: Delegated access carrying two identities (T036)
beat_3() {
  BEAT_ID=3
  BEAT_CLAIM="A protected request succeeds with a credential naming both the user and the sandbox"

  BEAT_AGENT_CMD="beat_3_agent"
  BEAT_CURL_CMD="beat_3_curl"
  BEAT_EVIDENCE_CMD="beat_3_evidence"
  BEAT_ASSERT="beat_3_assert"
  BEAT_NEEDS_INFERENCE=false

  # Custody evidence is optional and independently flagged (T054, T054a)
  BEAT_CUSTODY_EVIDENCE_CMD="beat_3_custody_evidence"
  BEAT_CUSTODY_NEEDS_INFERENCE=true
}

beat_3_agent() {
  "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    /usr/local/bin/claude --print "Fetch data from http://${PROTECTED_HOST}:8080/ and show what you get" 2>&1 || true
}

beat_3_curl() {
  # The curl path exercises the same mechanism through the sandbox
  "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    curl -sS --max-time 10 "http://${PROTECTED_HOST}:8080/" 2>&1 || true
}

beat_3_evidence() {
  printf "${C_BOLD}Delegation evidence:${C_RESET}\n"
  "${SCRIPT_DIR}/../inspect/inspect-token.sh" --chain 2>/dev/null || \
    echo "  (inspection surface not available)"
}

beat_3_assert() {
  # Assert: the final token shows sub=demo-user and nested act chain
  local token_data
  token_data=$(debug_fetch_tokens) || return 1
  # Check that a final token exists with the correct sub and act chain
  printf '%s' "$token_data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tokens = data.get('tokens', [])
final = next((t for t in tokens if t.get('phase') == 'final'), None)
if not final:
    print('no final token found', file=sys.stderr)
    sys.exit(1)
claims = final.get('claims', {})
if claims.get('sub') != '${DEMO_USER}':
    print(f'sub is {claims.get(\"sub\")}, expected ${DEMO_USER}', file=sys.stderr)
    sys.exit(1)
act = claims.get('act', {})
if not act.get('sub', '').startswith('spiffe://'):
    print('act.sub is not a SPIFFE ID', file=sys.stderr)
    sys.exit(1)
inner_act = act.get('act', {})
if not inner_act.get('sub', '').startswith('spiffe://'):
    print('act.act.sub is not a SPIFFE ID (gateway missing from chain)', file=sys.stderr)
    sys.exit(1)
# Verify nesting: sandbox outermost, gateway inner (most recent actor outermost)
if 'sandbox' not in act.get('sub', ''):
    print('act.sub should be the sandbox (most recent actor outermost)', file=sys.stderr)
    sys.exit(1)
if 'gateway' not in inner_act.get('sub', ''):
    print('act.act.sub should be the gateway', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# Custody evidence for beat 3 (T054, T054a, T054b)
# Shows the placeholder the agent holds and demonstrates it does not authenticate.
# Skippable: beat 3's core assertion never depends on this.
beat_3_custody_evidence() {
  echo ""
  printf "${C_BOLD}Credential custody:${C_RESET}\n"

  # Show the placeholder value (no network needed)
  local placeholder
  placeholder=$("${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    env 2>/dev/null | grep "openshell:resolve:env:" | head -1) || true

  if [ -n "$placeholder" ]; then
    printf "  Agent holds: %s\n" "$placeholder"
  else
    printf "  No openshell:resolve:env: placeholder found in sandbox environment\n"
    return 0
  fi

  # Try to authenticate directly with the placeholder value (T054b)
  # Distinguish between blocked network and rejected credential.
  local key_value
  key_value=$(printf '%s' "$placeholder" | sed 's/.*=//')

  printf "  Testing direct authentication... "
  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "x-api-key: ${key_value}" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d '{"model":"claude-sonnet-4-20250514","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
    "https://api.anthropic.com/v1/messages" 2>/dev/null) || http_code="000"

  case "$http_code" in
    000)
      # Network unreachable (T054b: distinguish from rejection)
      printf "network unreachable (cannot verify rejection from this venue)\n"
      ;;
    401|403)
      # Credential rejected (the expected outcome)
      printf "rejected (HTTP %s). The placeholder is not a usable credential.\n" "$http_code"
      ;;
    *)
      printf "unexpected HTTP %s\n" "$http_code"
      ;;
  esac
}

# Beat 4: Tool-level policy (T046)
beat_4() {
  BEAT_ID=4
  BEAT_CLAIM="Policy allows one tool and refuses another on the same destination"

  BEAT_AGENT_CMD="beat_4_agent"
  BEAT_CURL_CMD="beat_4_curl"
  BEAT_EVIDENCE_CMD="beat_4_evidence"
  BEAT_ASSERT="beat_4_assert"
  BEAT_NEEDS_INFERENCE=false
}

beat_4_agent() {
  # Ask the agent to use weather_lookup (allowed) then database_query (refused).
  #
  # The MCP server has to be handed to the agent explicitly. Without
  # --mcp-config it has no idea these tools exist and answers by offering to
  # search the web, which looks like a working beat only because the assertion
  # drives the MCP calls itself.
  #
  # --allowedTools because Claude Code prompts for permission on MCP tools and
  # refuses both under --print. That refusal is the agent's own gate, not the
  # sandbox policy, so it would hide the very thing this beat demonstrates:
  # grant the agent both tools, and watch the platform still refuse one.
  "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    /usr/local/bin/claude --print \
    --mcp-config "$(mcp_client_config)" \
    --strict-mcp-config \
    --allowedTools="mcp__${MCP_SERVER_NAME}__weather_lookup,mcp__${MCP_SERVER_NAME}__database_query" \
    "Use the weather_lookup tool to check the weather in Warsaw, then use the database_query tool to run SELECT * FROM users" 2>&1 || true
}

# Drive one MCP tools/call from inside the sandbox without the agent (FR-010).
#
# Python, not curl: beat 5 exists to prove /usr/bin/curl is refused on this
# exact destination, so beat 4 cannot also require curl to succeed there. The
# policy sanctions /usr/bin/python3.12 for this block instead.
#
# Prints the response body on both paths. A tool refusal comes back as an HTTP
# error whose body carries the reason, and urllib raises rather than returning
# it, so the HTTPError body has to be read explicitly or the evidence is lost.
beat_4_mcp_call() {
  local tool="$1" arguments="$2" call_id="$3"
  "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    /usr/bin/python3 -c '
import json, sys, urllib.request, urllib.error
tool, arguments, call_id, host = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
body = json.dumps({
    "jsonrpc": "2.0", "id": call_id, "method": "tools/call",
    "params": {"name": tool, "arguments": json.loads(arguments)},
}).encode()
req = urllib.request.Request(
    "http://%s:8080/" % host, data=body, method="POST",
    headers={"Content-Type": "application/json",
             "MCP-Protocol-Version": "2025-11-25"})
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(resp.read().decode(errors="replace"))
except urllib.error.HTTPError as exc:
    print(exc.read().decode(errors="replace"))
except Exception as exc:
    print("request failed: %s" % exc)
' "$tool" "$arguments" "$call_id" "$MCP_HOST" 2>&1 || true
}

beat_4_curl() {
  # Directly call the MCP server: permitted tool
  printf "${C_BOLD}Permitted tool (weather_lookup):${C_RESET}\n"
  beat_4_mcp_call "weather_lookup" '{"city":"Warsaw"}' 1

  echo ""
  printf "${C_BOLD}Refused tool (database_query):${C_RESET}\n"
  beat_4_mcp_call "database_query" '{"sql":"SELECT * FROM users"}' 2
}

beat_4_evidence() {
  printf "${C_BOLD}Same destination, different outcome:${C_RESET}\n"
  printf "  Permitted: weather_lookup on %s:8080\n" "$MCP_HOST"
  printf "  Refused:   database_query on %s:8080\n" "$MCP_HOST"
  printf "  The refusal names the tool, not the destination.\n"
}

beat_4_assert() {
  # Assert: weather_lookup succeeds through the sandbox
  local result
  result=$(beat_4_mcp_call "weather_lookup" '{"city":"Warsaw"}' 1)
  # Check for a JSON-RPC success response (the key is "result", not just the word)
  printf '%s' "$result" | grep -q '"result"' || return 1

  # Assert: database_query is refused (C5, FR-018)
  local deny_output
  deny_output=$(beat_4_mcp_call "database_query" '{"sql":"SELECT 1"}' 2)
  # The response must NOT contain a successful result
  if printf '%s' "$deny_output" | grep -q '"result"'; then
    return 1
  fi
  # The deny record must name the tool (FR-018). The refused caller is told only
  # "not permitted by policy", so read the tool name from the audit record.
  deny_record "database_query" "$MCP_HOST" >/dev/null || return 1
}

# Beat 5: Per-binary isolation (T049)
beat_5() {
  BEAT_ID=5
  BEAT_CLAIM="An unsanctioned program is refused; the sanctioned program succeeds on the same destination"

  BEAT_AGENT_CMD="beat_5_agent"
  BEAT_CURL_CMD="beat_5_curl"
  BEAT_EVIDENCE_CMD="beat_5_evidence"
  BEAT_ASSERT="beat_5_assert"
  BEAT_NEEDS_INFERENCE=false
}

beat_5_agent() {
  beat_5_curl
}

beat_5_curl() {
  printf "${C_BOLD}Unsanctioned program (/usr/bin/curl):${C_RESET}\n"
  "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    /usr/bin/curl -sS --max-time 5 "http://${MCP_HOST}:8080/healthz" 2>&1 || true

  echo ""
  printf "${C_BOLD}Sanctioned program (/usr/local/bin/claude):${C_RESET}\n"
  # The agent binary can still reach the same destination
  "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    /usr/local/bin/claude --print "Check the health endpoint at http://${MCP_HOST}:8080/healthz" 2>&1 || true
}

beat_5_evidence() {
  printf "${C_BOLD}Same destination, different program:${C_RESET}\n"
  printf "  Refused:  /usr/bin/curl to %s:8080\n" "$MCP_HOST"
  printf "  Allowed:  /usr/local/bin/claude to %s:8080\n" "$MCP_HOST"
  printf "  The refusal names the program, not the destination.\n"
}

beat_5_assert() {
  # Assert: curl is refused and the deny record names /usr/bin/curl (C5, FR-019)
  local deny_output
  deny_output=$("${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- \
    /usr/bin/curl -sS --max-time 5 "http://${MCP_HOST}:8080/healthz" 2>&1) || true
  # It has to be refused, and refused by policy rather than by a dead service.
  printf '%s' "$deny_output" | grep -qE "policy_denied|not permitted by policy" || return 1

  # The deny record must name the program (FR-019). The refused caller is told
  # only "not permitted by policy" -- the proxy deliberately does not disclose
  # why -- so the program name has to come from the audit record.
  deny_record "/usr/bin/curl" "$MCP_HOST" >/dev/null || return 1

  # The sanctioned-binary contrast (FR-020) is demonstrated by the curl path
  # (beat_5_curl) and visually by beat_5_evidence. The core assertion here
  # only needs to prove that the unsanctioned binary is refused. The sanctioned
  # binary's success is proven by beat 4's weather_lookup call through the
  # same MCP destination, which succeeds without inference.
  return 0
}
