#!/usr/bin/env bash
# Shared environment, output helpers, and readiness checks for the OBO demo.

set -euo pipefail

# ── Environment resolution ──────────────────────────────────────────

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$DEMO_DIR/.." && pwd)"

# External read-only worktree (FR-030: never modified)
OPENSHELL_WORKTREE="${OPENSHELL_WORKTREE:-$HOME/Development/OpenShell-demo}"

# The runtime images must come from the same upstream commit as the worktree
# scripts (FR-029). The `:latest` tags lag main and speak an older gateway
# config schema: they reject `compute_driver` (schema v2, what the pinned
# start-gateway.sh writes) and expect the retired `compute_drivers`. Pinning
# both sides to one commit removes that skew and makes a rerun weeks from now
# behave exactly as rehearsed.
# Pinned to the v0.0.116 release commit rather than an arbitrary main commit.
# A release is the only point where all three pieces exist and agree: the
# worktree scripts, published gateway/supervisor images, and a published CLI
# binary. The earlier pin (02b664bb) had gateway images but no CLI build, and a
# newer CLI fails against it with "workspace_scope is required" because the
# proto had moved on. v0.0.116 postdates the SPIFFE token exchange support
# (#1970), so nothing this demo needs is lost.
OPENSHELL_PIN="${OPENSHELL_PIN:-d1155aa70042d3e2ee49dbfa15346b108b7c1d92}"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/gateway:${OPENSHELL_PIN}}"
SUPERVISOR_IMAGE="${SUPERVISOR_IMAGE:-ghcr.io/nvidia/openshell/supervisor:${OPENSHELL_PIN}}"

# Podman network shared by all demo containers
DEMO_NETWORK="openshell"

# Container names (prefixed for easy teardown identification)
CONTAINER_SPIRE_SERVER="openshell-spiffe-demo-spire-server"
CONTAINER_SPIRE_AGENT="openshell-spiffe-demo-spire-agent"
CONTAINER_OIDC_PROVIDER="openshell-spiffe-demo-oidc-provider"
CONTAINER_ISSUER="openshell-spiffe-demo-issuer"
CONTAINER_PROTECTED="openshell-spiffe-demo-alpha"
CONTAINER_MCP="openshell-spiffe-demo-mcp"
CONTAINER_GATEWAY="openshell-spiffe-demo-gateway"

# All demo containers for iteration
DEMO_CONTAINERS=(
  "$CONTAINER_SPIRE_SERVER"
  "$CONTAINER_SPIRE_AGENT"
  "$CONTAINER_OIDC_PROVIDER"
  "$CONTAINER_ISSUER"
  "$CONTAINER_PROTECTED"
  "$CONTAINER_MCP"
  "$CONTAINER_GATEWAY"
)

# Ports (host-published)
PORT_ISSUER=8097
PORT_PROTECTED=8099
PORT_MCP=8100
PORT_GATEWAY=8101
PORT_SPIRE_OIDC=8443

# Debug inspection socket (container-internal UNIX domain socket, no TCP port).
# The debug surface is topologically unreachable from the demo network because
# there is no TCP listener to connect to (C3).
DEBUG_SOCKET_PATH="/tmp/debug.sock"

# Sandbox name (19 chars or fewer, Podman driver limit)
SANDBOX_NAME="obo-demo"

# The delegation provider instance. Deliberately not "obo-demo": that is the
# profile id, i.e. the *type*. `--name obo-demo --type obo-demo` reads as a
# tautology on stage and hides the distinction between a type and an instance
# of it. Named for what it actually holds.
DELEGATION_PROVIDER="obo-user-token"

# Gateway CLI name: single source of truth for all scripts and tests (C1)
GATEWAY_CLI_NAME="obo-demo"

# SPIFFE trust domain and IDs
TRUST_DOMAIN="openshell.local"
SPIFFE_PREFIX="spiffe://${TRUST_DOMAIN}/openshell"
GATEWAY_SPIFFE_ID="${SPIFFE_PREFIX}/gateway/demo"

# Selector the gateway's SPIRE entry must carry. The container label is unique
# to the gateway; a UID selector is either wrong (the agent's user namespace
# remaps it) or far too broad (every rootless container process is uid 0).
GATEWAY_SPIRE_SELECTOR="docker:label:openshell.spiffe-demo:gateway"

# Token issuer network alias (resolvable inside the demo network)
ISSUER_HOST="token-issuer.default.svc.cluster.local"
PROTECTED_HOST="alpha.default.svc.cluster.local"
MCP_HOST="mcp.default.svc.cluster.local"

# Access token secret (generated once per bring-up, never written to disk)
ACCESS_TOKEN_SECRET="${ACCESS_TOKEN_SECRET:-}"

# Demo user identifier (constant for the demo)
DEMO_USER="demo-user"

# ── Inference backend ───────────────────────────────────────────────
#
# OBO_INFERENCE selects how the agent reaches a model:
#   vertex  Google Vertex AI. The gateway holds the refresh material and mints
#           a one-hour bearer token, rotating it 300s before expiry. The
#           sandbox never holds either the bootstrap material or a long-lived
#           secret, which argues the talk's thesis rather than just
#           illustrating it.
#   apikey  Static Anthropic API key. Simplest, and the agent holds an
#           `openshell:resolve:env:` placeholder the proxy substitutes.
#   none    No inference. Beats needing the agent fall back to --curl.
#   auto    (default) vertex if gcloud ADC is present, else apikey if
#           ANTHROPIC_API_KEY is set, else none.
#
# Subscription auth is deliberately unsupported: it has no provider profile,
# needs an interactive browser login, and would place a working credential
# inside the sandbox, contradicting the claim the demo makes on stage.
OBO_INFERENCE="${OBO_INFERENCE:-auto}"

# Home directory that owns the gcloud configuration, to present to
# `provider create --from-gcloud-adc`. Inside the Podman machine VM $HOME is
# /var/home/core and holds no gcloud state, while the presenter's real home is
# mounted through, so probe for the ADC rather than assuming either one. The
# first candidate that actually has the file wins.
default_gcloud_home() {
  local candidate
  for candidate in "$HOME" /Users/* /home/*; do
    [ -d "$candidate" ] || continue
    [ -f "${candidate}/.config/gcloud/application_default_credentials.json" ] || continue
    printf '%s' "$candidate"
    return 0
  done
  printf '%s' "$HOME"
}
GCLOUD_ADC_HOME="${GCLOUD_ADC_HOME:-$(default_gcloud_home)}"
GCLOUD_ADC_FILE="${GCLOUD_ADC_HOME}/.config/gcloud/application_default_credentials.json"

# Project from the active gcloud configuration, so the demo follows whatever
# `gcloud config set project` selected instead of carrying one presenter's
# project name in the repository. Override with VERTEX_PROJECT_ID.
gcloud_active_project() {
  local cfg_dir="${GCLOUD_ADC_HOME}/.config/gcloud"
  local active cfg
  [ -r "${cfg_dir}/active_config" ] || return 1
  active="$(cat "${cfg_dir}/active_config" 2>/dev/null)" || return 1
  [ -n "$active" ] || return 1
  cfg="${cfg_dir}/configurations/config_${active}"
  [ -r "$cfg" ] || return 1
  sed -n 's/^[[:space:]]*project[[:space:]]*=[[:space:]]*//p' "$cfg" | head -1
}

# Vertex project and region. Region `global` is what the local setup uses.
VERTEX_PROJECT_ID="${VERTEX_PROJECT_ID:-$(gcloud_active_project || true)}"
VERTEX_REGION="${VERTEX_REGION:-${CLOUD_ML_REGION:-global}}"

# Model served over `inference.local` when the Vertex backend is selected.
VERTEX_MODEL="${VERTEX_MODEL:-claude-sonnet-4-6}"

# Resolve OBO_INFERENCE=auto into a concrete mode.
resolve_inference_mode() {
  case "$OBO_INFERENCE" in
    vertex|apikey|none) printf '%s' "$OBO_INFERENCE" ;;
    auto)
      # Vertex first when the ADC is present: the gateway mints and rotates the
      # token, so the sandbox holds no credential at all, which is the stronger
      # version of the talk's claim. Fall back to the static key, then to none.
      if [ -f "$GCLOUD_ADC_FILE" ]; then
        printf 'vertex'
      elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        printf 'apikey'
      else
        printf 'none'
      fi
      ;;
    *) printf 'none' ;;
  esac
}

# ── Output helpers ──────────────────────────────────────────────────

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
  C_GREEN='\033[0;32m'
  C_RED='\033[0;31m'
  C_YELLOW='\033[0;33m'
  C_CYAN='\033[0;36m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_RESET='\033[0m'
else
  C_GREEN='' C_RED='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
fi

info()  { printf "${C_CYAN}[info]${C_RESET}  %s\n" "$*"; }
ok()    { printf "${C_GREEN}[  ok]${C_RESET}  %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[warn]${C_RESET}  %s\n" "$*" >&2; }
fail()  { printf "${C_RED}[FAIL]${C_RESET}  %s\n" "$*" >&2; }

# Readiness table rendering (FR-003)
# Usage: readiness_row <component> <state> [detail]
#   state: ready | starting | failed
readiness_row() {
  local component="$1" state="$2" detail="${3:-}"
  local icon
  case "$state" in
    ready)    icon="${C_GREEN}ready${C_RESET}" ;;
    starting) icon="${C_YELLOW}starting${C_RESET}" ;;
    failed)   icon="${C_RED}FAILED${C_RESET}" ;;
    *)        icon="$state" ;;
  esac
  if [ -n "$detail" ]; then
    printf "  %-30s %b  %s\n" "$component" "$icon" "$detail"
  else
    printf "  %-30s %b\n" "$component" "$icon"
  fi
}

# Actionable failure message (FR-003)
actionable_fail() {
  local component="$1" reason="$2"
  fail "$component: $reason"
}

# ── No-secrets guard (FR-031) ───────────────────────────────────────

# Mask a credential for display. Shows first 4 and last 4 chars only.
mask_credential() {
  local val="$1"
  local len=${#val}
  if [ "$len" -le 12 ]; then
    printf '****'
  else
    printf '%s...%s' "${val:0:4}" "${val:$((len-4)):4}"
  fi
}

# ── Expired-credential detector (FR-033) ────────────────────────────

# Check if an error message indicates an expired token.
# Returns 0 if expired, 1 otherwise.
is_expired_token_error() {
  local msg="$1"
  case "$msg" in
    *expired_token*|*"token expired"*|*"JWT-SVID expired"*|*"access token expired"*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Report expiry as the cause rather than a raw error (FR-033)
report_credential_error() {
  local component="$1" error_msg="$2"
  if is_expired_token_error "$error_msg"; then
    actionable_fail "$component" "credential expired. Re-run bring-up.sh to mint fresh tokens"
  else
    actionable_fail "$component" "$error_msg"
  fi
}

# ── Readiness checks ───────────────────────────────────────────────

# Check if a container exists and is running
container_is_running() {
  local name="$1"
  podman container inspect --format '{{.State.Running}}' "$name" 2>/dev/null | grep -q true
}

# Check if a container exists (any state)
container_exists() {
  local name="$1"
  podman container inspect "$name" >/dev/null 2>&1
}

# Wait for an HTTP endpoint to respond 200
wait_for_http() {
  local url="$1" max_attempts="${2:-30}" delay="${3:-1}"
  local attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    if curl -sf --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep "$delay"
  done
  return 1
}

# Decode a JWT payload (no verification, display only)
jwt_payload() {
  local jwt="$1"
  local payload
  payload=$(echo "$jwt" | cut -d. -f2)
  # Add padding
  local pad=$((4 - ${#payload} % 4))
  [ "$pad" -ne 4 ] && payload="${payload}$(printf '=%.0s' $(seq 1 "$pad"))"
  echo "$payload" | base64 -d 2>/dev/null | python3 -m json.tool 2>/dev/null
}

# Read expiry from a JWT, return seconds remaining
jwt_seconds_remaining() {
  local jwt="$1"
  local payload exp now remaining
  payload=$(echo "$jwt" | cut -d. -f2)
  local pad=$((4 - ${#payload} % 4))
  [ "$pad" -ne 4 ] && payload="${payload}$(printf '=%.0s' $(seq 1 "$pad"))"
  exp=$(echo "$payload" | base64 -d 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('exp',0))" 2>/dev/null)
  now=$(date +%s)
  remaining=$((exp - now))
  echo "$remaining"
}

# ── Debug inspection helper (C3) ───────────────────────────────────

# Fetch tokens from the debug inspection socket inside the issuer container.
# The debug surface runs on a UNIX domain socket (no TCP port), so it is
# topologically unreachable from the demo network.
debug_fetch_tokens() {
  podman exec "$CONTAINER_ISSUER" \
    curl -sf --unix-socket "$DEBUG_SOCKET_PATH" "http://localhost/debug/last-token" 2>/dev/null
}

# ── Component config fingerprint ────────────────────────────────────

# Stable hash of the environment a component is started with.
#
# Stored as a container label at creation and compared on every re-run, so a
# container built with different settings is replaced rather than silently
# reused. A named list of "env vars that matter" would drift out of date the
# moment someone adds one, which is the failure this is here to prevent, so
# hash whatever is actually passed.
#
# The values include ACCESS_TOKEN_SECRET. What lands in the label is a SHA-256
# over 32 bytes of entropy, which is not a disclosure, and it never leaves the
# local container.
env_fingerprint() {
  local hasher
  if command -v sha256sum >/dev/null 2>&1; then
    hasher=(sha256sum)
  else
    hasher=(shasum -a 256)
  fi
  printf '%s\n' "$@" | LC_ALL=C sort | "${hasher[@]}" | cut -d' ' -f1
}

# Expand KEY=VALUE pairs into the `-e KEY=VALUE` flags podman run expects.
# Writes to the array named by the first argument, so each flag and its value
# stay separate words rather than relying on `-eKEY=VALUE` parsing.
podman_env_flags() {
  local -n out="$1"
  shift
  out=()
  local pair
  for pair in "$@"; do
    out+=(-e "$pair")
  done
}

# ── MCP client config ───────────────────────────────────────────────

# Name the agent's MCP server is registered under. Tool permissions are keyed
# on it, as mcp__<server>__<tool>.
MCP_SERVER_NAME="obo-demo"

# The --mcp-config payload handed to the agent, inline rather than as a file:
# the rendered mcp-config.json lives in the repo, which is not mounted into the
# sandbox, so a path would not resolve there.
mcp_client_config() {
  printf '{"mcpServers":{"%s":{"type":"http","url":"http://%s:8080/"}}}' \
    "$MCP_SERVER_NAME" "$MCP_HOST"
}

# ── Sandbox helpers ─────────────────────────────────────────────────

# Resolve a sandbox name to the UUID the gateway assigned it.
#
# SPIRE entries are registered under this UUID, never under the name, so any
# caller building a sandbox SPIFFE ID has to go through here first. Passing the
# name straight to sandbox_spiffe_id yields an ID that matches no entry and
# fails silently, which is what beat 2 did.
sandbox_uuid() {
  local name="${1:-$SANDBOX_NAME}"
  openshell --gateway "$GATEWAY_CLI_NAME" \
    --gateway-endpoint "http://127.0.0.1:${PORT_GATEWAY}" \
    sandbox list --output json 2>/dev/null | \
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sandboxes = data if isinstance(data, list) else data.get('sandboxes', [])
for s in sandboxes:
    if s.get('name') == '${name}':
        print(s.get('id', ''))
        break
" 2>/dev/null
}

sandbox_spiffe_id() {
  local sandbox_id="$1"
  echo "${SPIFFE_PREFIX}/sandbox/${sandbox_id}"
}

# Most recent DENIED record in the sandbox audit log matching every argument.
#
# The proxy deliberately tells the caller nothing about why it refused: the
# response body is a flat "not permitted by policy". The tool name, the calling
# binary and the policy that refused all live in the audit record instead, so
# any assertion about *what* was named has to read it from here rather than
# from the refused command's own output.
deny_record() {
  # The sandbox batches activity and flushes it to the gateway ("Flushed
  # activity summary to gateway"), so the record for a refusal that just
  # happened is not in the log yet. Poll rather than read once: a single read
  # races the flush and turns a working denial into a failed assertion.
  local deadline=$((SECONDS + ${DENY_RECORD_TIMEOUT_SECS:-20}))
  local out pattern found
  while :; do
    out=$(openshell --gateway "$GATEWAY_CLI_NAME" \
      --gateway-endpoint "http://127.0.0.1:${PORT_GATEWAY}" \
      logs "$SANDBOX_NAME" -n 500 --source sandbox 2>/dev/null | grep -F "DENIED") || out=""
    if [ -n "$out" ]; then
      found="$out"
      for pattern in "$@"; do
        found=$(printf '%s\n' "$found" | grep -F -- "$pattern") || { found=""; break; }
      done
      if [ -n "$found" ]; then
        printf '%s\n' "$found" | tail -1
        return 0
      fi
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}
