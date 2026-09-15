#!/usr/bin/env bash
# Idempotent environment bring-up for the OBO demo.
# FR-001: Single helper, cold start to ready state.
# FR-002: Safe to re-run; repairs rather than duplicating.
# FR-003: Per-component readiness with actionable failure messages.
# FR-034: Reports remaining credential validity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demo/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── Persistent state ──────────────────────────────────────────────
# SPIRE creates unix sockets here and then chmods them. That fails with
# "invalid argument" on any filesystem shared from a macOS host (virtiofs),
# which crashes the SPIRE server on startup and cascades into every other
# component. The state directory must therefore live on a filesystem native
# to whatever runs the containers. Override with OBO_STATE_DIR when the repo
# itself sits on a shared mount, for example /var/tmp/obo-demo inside a
# Podman machine VM.
STATE_DIR="${OBO_STATE_DIR:-${DEMO_DIR}/.state}"
SPIRE_STATE_DIR="${STATE_DIR}/spire"
GATEWAY_STATE_DIR="${STATE_DIR}/gateway"
SECRET_FILE="${STATE_DIR}/access-token-secret"
TOKEN_FILE="${STATE_DIR}/subject-token"
SPIRE_ENV_FILE="${STATE_DIR}/spire.env"
GATEWAY_ENV_FILE="${STATE_DIR}/gateway.env"

mkdir -p "$STATE_DIR" "$SPIRE_STATE_DIR" "$GATEWAY_STATE_DIR"

# Fail here rather than six components later. OPENSHELL_WORKTREE defaults to a
# path under $HOME, which is wrong whenever bring-up runs somewhere $HOME is not
# the presenter's account, such as inside a Podman machine VM where $HOME is
# /var/home/core. Without this check every delegated upstream script silently
# fails to be found and the readiness table blames SPIRE and the gateway instead.
# The gateway keeps a migrated database under its state directory. Changing the
# pin can move that database backwards, and the gateway then refuses to start
# with "migration N was previously applied but is missing in the resolved
# migrations". State from a different pin is not repairable, so discard it.
PIN_STAMP="${STATE_DIR}/pin"
if [ -f "$PIN_STAMP" ] && [ "$(cat "$PIN_STAMP")" != "$OPENSHELL_PIN" ]; then
  info "Pin changed to ${OPENSHELL_PIN}; resetting gateway state"
  podman rm -f "$CONTAINER_GATEWAY" >/dev/null 2>&1 || true
  rm -rf "${GATEWAY_STATE_DIR:?}"/*
fi
printf '%s' "$OPENSHELL_PIN" > "$PIN_STAMP"

if [ ! -d "${OPENSHELL_WORKTREE}/examples/spiffe-token-exchange-demo/podman" ]; then
  printf 'FAIL: OpenShell worktree not found at %s\n' "$OPENSHELL_WORKTREE" >&2
  printf '      bring-up delegates SPIRE and gateway startup to scripts there.\n' >&2
  printf '      Set OPENSHELL_WORKTREE to the checkout pinned at %s\n' "$OPENSHELL_PIN" >&2
  exit 1
fi

# ── Access token secret (persisted for idempotence) ──────────────
if [ -f "$SECRET_FILE" ]; then
  ACCESS_TOKEN_SECRET=$(cat "$SECRET_FILE")
else
  ACCESS_TOKEN_SECRET=$(openssl rand -hex 32)
  printf '%s' "$ACCESS_TOKEN_SECRET" > "$SECRET_FILE"
  chmod 0600 "$SECRET_FILE"
fi
export ACCESS_TOKEN_SECRET

# ── Readiness tracking ───────────────────────────────────────────
READINESS=()
ALL_READY=true

add_readiness() {
  local component="$1" state="$2" detail="${3:-}"
  READINESS+=("${component}|${state}|${detail}")
  if [ "$state" != "ready" ]; then
    ALL_READY=false
  fi
}

# ── Component lifecycle helpers (T017) ───────────────────────────
# Try to ensure a container is running. Returns 0 if already running
# or successfully restarted; returns 1 if it needs fresh creation.
# Optional second argument is the image the component must be running. A
# container built from a different image is replaced rather than restarted,
# because otherwise pinning an image has no effect on an environment that was
# first brought up before the pin.
#
# A restarted container is re-checked after a settle delay. Without it a
# container that starts and immediately crashes (a bad config, say) passes the
# instantaneous check and gets reported ready, which is worse than reporting a
# failure: the presenter reads "ready" and walks on stage with a dead component.
ensure_component() {
  local name="$1" expected_image="${2:-}" expected_alias="${3:-}" expected_env_fp="${4:-}"

  if [ -n "$expected_image" ] && container_exists "$name"; then
    local actual_image
    actual_image="$(podman container inspect --format '{{.ImageName}}' "$name" 2>/dev/null || true)"
    if [ -n "$actual_image" ] && [ "$actual_image" != "$expected_image" ]; then
      info "Replacing $name: image is $actual_image, expected $expected_image"
      podman rm -f "$name" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  # A network alias can only be set at creation, and a container carrying the
  # wrong one looks perfectly healthy: it runs, it answers its health check,
  # and it gets reported ready. Every request to it then dies in DNS instead,
  # far away from here. The upstream demo's own compose uses *.demo.local
  # aliases for the same container names, so reusing whatever is running is
  # how the demo ends up asserting on names that do not resolve.
  if [ -n "$expected_alias" ] && container_exists "$name"; then
    local actual_aliases
    actual_aliases="$(podman container inspect --format \
      '{{range $net, $conf := .NetworkSettings.Networks}}{{range $conf.Aliases}}{{.}} {{end}}{{end}}' \
      "$name" 2>/dev/null || true)"
    if ! printf '%s' "$actual_aliases" | grep -qw -- "$expected_alias"; then
      info "Replacing $name: network alias is [${actual_aliases% }], expected $expected_alias"
      podman rm -f "$name" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  # Environment is fixed at creation too, so editing a setting in this script
  # does nothing to a container that is already up. That is how an issuer
  # carrying a stale SPIRE_ISSUER survived a re-run and rejected every SVID.
  # A container created before fingerprinting has no label and is replaced
  # once, which is the safe direction.
  if [ -n "$expected_env_fp" ] && container_exists "$name"; then
    local actual_env_fp
    actual_env_fp="$(podman container inspect \
      --format '{{index .Config.Labels "obo.env-fingerprint"}}' "$name" 2>/dev/null || true)"
    if [ "$actual_env_fp" != "$expected_env_fp" ]; then
      info "Replacing $name: environment changed since it was created"
      podman rm -f "$name" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  if container_is_running "$name" && container_stays_running "$name"; then
    return 0
  fi
  if container_exists "$name"; then
    info "Restarting stopped container: $name"
    if podman start "$name" >/dev/null 2>&1 && container_stays_running "$name"; then
      return 0
    fi
    info "Replacing broken container: $name"
    podman rm -f "$name" >/dev/null 2>&1 || true
  fi
  return 1
}

# Confirm a container is still running after a settle delay, so a crash loop
# cannot be mistaken for a healthy start.
container_stays_running() {
  local name="$1"
  sleep "${COMPONENT_SETTLE_SECS:-3}"
  container_is_running "$name"
}

# ── Podman network ───────────────────────────────────────────────
ensure_network() {
  if ! podman network exists "$DEMO_NETWORK" >/dev/null 2>&1; then
    info "Creating Podman network: $DEMO_NETWORK"
    podman network create "$DEMO_NETWORK" >/dev/null 2>&1
  fi
}

# ── SPIRE (T013) ─────────────────────────────────────────────────
start_spire() {
  local spire_dir="${OPENSHELL_WORKTREE}/examples/spiffe-token-exchange-demo/podman/spire"

  # Check if all SPIRE components are running
  local all_running=true
  for c in "$CONTAINER_SPIRE_SERVER" "$CONTAINER_OIDC_PROVIDER" "$CONTAINER_SPIRE_AGENT"; do
    if ! container_is_running "$c"; then
      all_running=false
    fi
  done

  if $all_running; then
    for c in "$CONTAINER_SPIRE_SERVER" "$CONTAINER_OIDC_PROVIDER" "$CONTAINER_SPIRE_AGENT"; do
      add_readiness "$c" "ready"
    done
    return
  fi

  # Try restarting stopped containers
  for c in "$CONTAINER_SPIRE_SERVER" "$CONTAINER_OIDC_PROVIDER" "$CONTAINER_SPIRE_AGENT"; do
    if container_exists "$c" && ! container_is_running "$c"; then
      podman start "$c" >/dev/null 2>&1 || true
    fi
  done

  # Check again after restart attempt
  all_running=true
  for c in "$CONTAINER_SPIRE_SERVER" "$CONTAINER_OIDC_PROVIDER" "$CONTAINER_SPIRE_AGENT"; do
    if ! container_is_running "$c"; then
      all_running=false
    fi
  done

  if $all_running; then
    for c in "$CONTAINER_SPIRE_SERVER" "$CONTAINER_OIDC_PROVIDER" "$CONTAINER_SPIRE_AGENT"; do
      add_readiness "$c" "ready"
    done
    return
  fi

  # Need fresh creation: clean up any partial state
  info "Starting SPIRE infrastructure..."
  for c in "$CONTAINER_SPIRE_AGENT" "$CONTAINER_OIDC_PROVIDER" "$CONTAINER_SPIRE_SERVER"; do
    podman rm -f "$c" >/dev/null 2>&1 || true
  done

  # Server + OIDC discovery provider
  SPIRE_STATE_DIR="$SPIRE_STATE_DIR" \
  PODMAN_NETWORK="$DEMO_NETWORK" \
  SPIRE_SERVER_CONTAINER="$CONTAINER_SPIRE_SERVER" \
  SPIRE_OIDC_CONTAINER="$CONTAINER_OIDC_PROVIDER" \
  OIDC_PORT="$PORT_SPIRE_OIDC" \
  SPIRE_ENV_FILE="$SPIRE_ENV_FILE" \
  CLEANUP_EXISTING=0 \
    bash "$spire_dir/start-server-oidc.sh" >"${STATE_DIR}/spire-server-start.log" 2>&1 || {
      actionable_fail "spire-server" \
        "SPIRE server/OIDC start failed. See ${STATE_DIR}/spire-server-start.log and podman logs $CONTAINER_SPIRE_SERVER"
      for c in "$CONTAINER_SPIRE_SERVER" "$CONTAINER_OIDC_PROVIDER" "$CONTAINER_SPIRE_AGENT"; do
        add_readiness "$c" "failed" "SPIRE startup failed"
      done
      return
    }

  # Agent
  SPIRE_STATE_DIR="$SPIRE_STATE_DIR" \
  PODMAN_NETWORK="$DEMO_NETWORK" \
  SPIRE_SERVER_CONTAINER="$CONTAINER_SPIRE_SERVER" \
  SPIRE_AGENT_CONTAINER="$CONTAINER_SPIRE_AGENT" \
  SPIRE_ENV_FILE="$SPIRE_ENV_FILE" \
  CLEANUP_EXISTING=0 \
    bash "$spire_dir/start-agent.sh" >"${STATE_DIR}/spire-agent-start.log" 2>&1 || {
      actionable_fail "spire-agent" \
        "SPIRE agent start failed. See ${STATE_DIR}/spire-agent-start.log and podman logs $CONTAINER_SPIRE_AGENT"
      add_readiness "$CONTAINER_SPIRE_AGENT" "failed" "agent start failed"
      return
    }

  # Register gateway SPIRE entry (idempotent, ok to fail if already exists).
  #
  # Select on the container label, not on `unix:uid:$(id -u)` as the upstream
  # script defaults to. Two reasons, and the demo hit both:
  #
  # 1. The agent attests by reading /proc/<pid>/status from inside its own user
  #    namespace. Under rootless Podman that maps this host's UID to 0, so an
  #    entry pinned to the host UID never matches and the agent answers "no
  #    identity issued" -- which surfaces far away as a bare `invalid_client`.
  # 2. Correcting it to unix:uid:0 then matches far too much: every rootless
  #    container process attests as uid 0, so the sandbox supervisor also
  #    picked up the gateway's identity and the exchange was refused with
  #    `unsupported_intermediate_audience`.
  #
  # The label is unique to this container, and it is what the sandbox entries
  # already use (docker:label:openshell.ai/sandbox-id:...).
  prune_gateway_spire_entries

  GATEWAY_SELECTORS="$GATEWAY_SPIRE_SELECTOR" \
    bash "$spire_dir/register-gateway.sh" >/dev/null 2>&1 || true

  # Report readiness
  for c in "$CONTAINER_SPIRE_SERVER" "$CONTAINER_OIDC_PROVIDER" "$CONTAINER_SPIRE_AGENT"; do
    if container_is_running "$c"; then
      add_readiness "$c" "ready"
    else
      add_readiness "$c" "failed" "container did not start"
    fi
  done
}

# ── SPIRE entry hygiene ──────────────────────────────────────────
#
# Entries are additive and nothing ever removed one, so they accumulated a
# sandbox entry per bring-up. Mostly noise, with one exception that cost real
# debugging time: a gateway entry left behind with an outdated selector keeps
# matching alongside the correct one, and the supervisor can then be issued the
# gateway's identity instead of its own.

spire_entries_json() {
  podman exec "$CONTAINER_SPIRE_SERVER" /opt/spire/bin/spire-server entry show \
    -socketPath /run/spire/server/private/api.sock -output json 2>/dev/null
}

spire_entry_delete() {
  podman exec "$CONTAINER_SPIRE_SERVER" /opt/spire/bin/spire-server entry delete \
    -socketPath /run/spire/server/private/api.sock -entryID "$1" >/dev/null 2>&1
}

# Delete the given entry IDs on stdin, reporting how many went.
spire_delete_ids() {
  local label="$1" count=0 entry_id
  while IFS= read -r entry_id; do
    [ -n "$entry_id" ] || continue
    spire_entry_delete "$entry_id" && count=$((count + 1))
  done
  [ "$count" -gt 0 ] && info "Pruned $count stale $label SPIRE entry/entries"
  return 0
}

# Gateway entries whose selectors are not exactly the one we register.
# Safe to run before the gateway is up: it needs nothing but SPIRE.
prune_gateway_spire_entries() {
  local entries
  entries="$(spire_entries_json)" || return 0
  [ -n "$entries" ] || return 0

  printf '%s' "$entries" | GATEWAY_SELECTOR="$GATEWAY_SPIRE_SELECTOR" python3 -c "
import json, os, sys
# SPIRE reports a selector split into type and value: 'docker' + 'label:...'
want_type, _, want_value = os.environ['GATEWAY_SELECTOR'].partition(':')
for entry in json.load(sys.stdin).get('entries', []):
    if entry.get('spiffe_id', {}).get('path') != '/openshell/gateway/demo':
        continue
    selectors = {(s.get('type'), s.get('value')) for s in entry.get('selectors', [])}
    if selectors != {(want_type, want_value)} and entry.get('id'):
        print(entry['id'])
" 2>/dev/null | spire_delete_ids "gateway"
}

# Sandbox entries for sandboxes the gateway no longer knows about.
#
# Must run with the gateway up. If `sandbox list` cannot be reached the answer
# would look like "no sandboxes are live" and this would delete the entry for
# the sandbox currently in use, so a failed lookup skips the prune entirely.
prune_orphaned_sandbox_entries() {
  local entries live
  entries="$(spire_entries_json)" || return 0
  [ -n "$entries" ] || return 0

  live="$("${OS_CMD[@]}" sandbox list --output json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
boxes = data if isinstance(data, list) else data.get('sandboxes', [])
print('\n'.join(filter(None, (b.get('id', '') for b in boxes))))
" 2>/dev/null)" || {
    warn "Could not list sandboxes; skipping SPIRE entry prune"
    return 0
  }

  printf '%s' "$entries" | LIVE="$live" python3 -c "
import json, os, sys
live = set(filter(None, os.environ.get('LIVE', '').split()))
for entry in json.load(sys.stdin).get('entries', []):
    path = entry.get('spiffe_id', {}).get('path', '')
    if path.startswith('/openshell/sandbox/') and entry.get('id'):
        if path.rsplit('/', 1)[-1] not in live:
            print(entry['id'])
" 2>/dev/null | spire_delete_ids "sandbox"
}

# ── Token issuer (T014) ──────────────────────────────────────────
start_issuer() {
  local issuer_url="http://${ISSUER_HOST}:8080"
  local jwks_url="http://spire-oidc:8080/keys"
  # Must match `jwt_issuer` in the upstream SPIRE server config, which is what
  # the server stamps into the `iss` claim of every JWT-SVID. The issuer
  # compares the two exactly, so an https/http mismatch here rejects the
  # gateway's SVID with a bare `invalid_client` and the delegation never runs.
  local spire_issuer="http://spire-oidc:8080"

  local env_args=(
    "PORT=8080"
    "DEBUG_SOCKET_PATH=${DEBUG_SOCKET_PATH}"
    "ACCESS_TOKEN_SECRET=${ACCESS_TOKEN_SECRET}"
    "SPIRE_JWKS_URI=${jwks_url}"
    "SPIRE_ISSUER=${spire_issuer}"
    "JWT_SVID_AUDIENCE=${issuer_url}"
    "ACCESS_TOKEN_ISSUER=${issuer_url}"
    "SUPERVISOR_TRUST_DOMAIN_PREFIX=${SPIFFE_PREFIX}/sandbox/"
    "GATEWAY_TRUST_DOMAIN_PREFIX=${SPIFFE_PREFIX}/gateway/"
  )
  local env_fp env_flags
  env_fp="$(env_fingerprint "${env_args[@]}")"
  podman_env_flags env_flags "${env_args[@]}"

  if ensure_component "$CONTAINER_ISSUER" "" "$ISSUER_HOST" "$env_fp"; then
    add_readiness "$CONTAINER_ISSUER" "ready"
    return
  fi

  info "Building and starting token issuer..."
  podman build -t obo-demo-issuer \
    -f "${DEMO_DIR}/issuer/Containerfile" "${DEMO_DIR}/issuer/" >/dev/null 2>&1

  podman run -d \
    --name "$CONTAINER_ISSUER" \
    --network "$DEMO_NETWORK" \
    --network-alias "$ISSUER_HOST" \
    --label "obo.env-fingerprint=${env_fp}" \
    -p "127.0.0.1:${PORT_ISSUER}:8080" \
    "${env_flags[@]}" \
    obo-demo-issuer >/dev/null 2>&1

  if wait_for_http "http://127.0.0.1:${PORT_ISSUER}/healthz" 30 1; then
    add_readiness "$CONTAINER_ISSUER" "ready"
  else
    add_readiness "$CONTAINER_ISSUER" "failed" "health check timed out after 30s"
  fi
}

# ── Protected service (T014) ─────────────────────────────────────
start_protected_service() {
  local protected_js="${OPENSHELL_WORKTREE}/examples/spiffe-token-exchange-demo/k8s/protected-service.js"
  local issuer_url="http://${ISSUER_HOST}:8080"

  local env_args=(
    "PORT=8080"
    "SERVICE_NAME=alpha"
    "EXPECTED_AUDIENCE=alpha"
    "EXPECTED_SCOPE=alpha"
    "ACCESS_TOKEN_SECRET=${ACCESS_TOKEN_SECRET}"
    "ACCESS_TOKEN_ISSUER=${issuer_url}"
  )
  local env_fp env_flags
  env_fp="$(env_fingerprint "${env_args[@]}")"
  podman_env_flags env_flags "${env_args[@]}"

  if ensure_component "$CONTAINER_PROTECTED" "" "$PROTECTED_HOST" "$env_fp"; then
    add_readiness "$CONTAINER_PROTECTED" "ready"
    return
  fi

  info "Starting protected service..."

  podman run -d \
    --name "$CONTAINER_PROTECTED" \
    --network "$DEMO_NETWORK" \
    --network-alias "$PROTECTED_HOST" \
    --label "obo.env-fingerprint=${env_fp}" \
    -p "127.0.0.1:${PORT_PROTECTED}:8080" \
    -v "${protected_js}:/app/protected-service.js:ro" \
    "${env_flags[@]}" \
    docker.io/library/node:22.22.1-slim \
    node /app/protected-service.js >/dev/null 2>&1

  if wait_for_http "http://127.0.0.1:${PORT_PROTECTED}/healthz" 30 1; then
    add_readiness "$CONTAINER_PROTECTED" "ready"
  else
    add_readiness "$CONTAINER_PROTECTED" "failed" "health check timed out after 30s"
  fi
}

# ── MCP server (T045) ────────────────────────────────────────────
start_mcp_server() {
  local env_args=("PORT=8080")
  local env_fp env_flags
  env_fp="$(env_fingerprint "${env_args[@]}")"
  podman_env_flags env_flags "${env_args[@]}"

  if ensure_component "$CONTAINER_MCP" "" "$MCP_HOST" "$env_fp"; then
    add_readiness "$CONTAINER_MCP" "ready"
    return
  fi

  info "Building and starting MCP server..."
  podman build -t obo-demo-mcp \
    -f "${DEMO_DIR}/mcp/Containerfile" "${DEMO_DIR}/mcp/" >/dev/null 2>&1

  podman run -d \
    --name "$CONTAINER_MCP" \
    --network "$DEMO_NETWORK" \
    --network-alias "$MCP_HOST" \
    --label "obo.env-fingerprint=${env_fp}" \
    -p "127.0.0.1:${PORT_MCP}:8080" \
    "${env_flags[@]}" \
    obo-demo-mcp >/dev/null 2>&1

  if wait_for_http "http://127.0.0.1:${PORT_MCP}/healthz" 30 1; then
    add_readiness "$CONTAINER_MCP" "ready"
  else
    add_readiness "$CONTAINER_MCP" "failed" "health check timed out after 30s"
  fi
}

# ── Gateway (T015) ───────────────────────────────────────────────
# The upstream script hardcodes `ttl_secs = 3600` for gateway-minted sandbox
# JWTs. That is right for Kubernetes and wrong here: a supervisor on a static
# token source cannot rebootstrap, so an hour after creation the relay dies with
# "RefreshSandboxToken returned Unauthenticated" and every `sandbox exec` fails
# with "relay open timed out" while `sandbox list` still reports Ready. The
# gateway-config docs call for 0 (non-expiring) on local single-player Podman
# gateways, which is this topology exactly. Without it the demo dies mid-talk
# after being brought up in the green room.
#
# This must run on every bring-up, including when the gateway is already up,
# otherwise a previously-started gateway keeps the time bomb armed.
ensure_gateway_jwt_ttl() {
  local gw_toml="${GATEWAY_STATE_DIR}/gateway.toml"
  [ -f "$gw_toml" ] || return 0
  grep -q '^ttl_secs = 0' "$gw_toml" && return 0

  info "Setting gateway_jwt ttl_secs = 0 (non-expiring, local gateway)"
  sed -i 's/^ttl_secs = [0-9]\+/ttl_secs = 0/' "$gw_toml"
  if container_exists "$CONTAINER_GATEWAY"; then
    podman restart "$CONTAINER_GATEWAY" >/dev/null 2>&1 || true
    sleep "${COMPONENT_SETTLE_SECS:-3}"
  fi
}

start_gateway() {
  if ensure_component "$CONTAINER_GATEWAY" "$GATEWAY_IMAGE"; then
    ensure_gateway_jwt_ttl
    if container_is_running "$CONTAINER_GATEWAY"; then
      add_readiness "$CONTAINER_GATEWAY" "ready"
    else
      add_readiness "$CONTAINER_GATEWAY" "failed" "gateway did not survive config update"
    fi
    return
  fi

  info "Starting OpenShell gateway..."
  local gateway_script="${OPENSHELL_WORKTREE}/examples/spiffe-token-exchange-demo/podman/start-gateway.sh"

  # Source SPIRE env for the agent socket path
  local agent_socket="${SPIRE_STATE_DIR}/agent/sockets/agent.sock"
  if [ -f "$SPIRE_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$SPIRE_ENV_FILE"
    agent_socket="${SPIRE_AGENT_SOCKET_HOST_PATH:-$agent_socket}"
  fi

  GATEWAY_CONTAINER="$CONTAINER_GATEWAY" \
  GATEWAY_STATE_DIR="$GATEWAY_STATE_DIR" \
  GATEWAY_PORT="$PORT_GATEWAY" \
  GATEWAY_HEALTH_PORT=$((PORT_GATEWAY + 1)) \
  GATEWAY_ID="obo-demo" \
  PODMAN_NETWORK="$DEMO_NETWORK" \
  SPIRE_AGENT_SOCKET_HOST_PATH="$agent_socket" \
  CLEANUP_EXISTING=0 \
  GATEWAY_IMAGE="$GATEWAY_IMAGE" \
  SUPERVISOR_IMAGE="$SUPERVISOR_IMAGE" \
  GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE" \
    bash "$gateway_script" >"${STATE_DIR}/gateway-start.log" 2>&1 || {
      actionable_fail "gateway" \
        "Gateway start failed. See ${STATE_DIR}/gateway-start.log and podman logs $CONTAINER_GATEWAY"
      add_readiness "$CONTAINER_GATEWAY" "failed" "gateway start failed"
      return
    }

  ensure_gateway_jwt_ttl

  if container_is_running "$CONTAINER_GATEWAY"; then
    add_readiness "$CONTAINER_GATEWAY" "ready"
  else
    add_readiness "$CONTAINER_GATEWAY" "failed" "gateway did not start"
  fi
}

# ── Sandbox and provider (T016, T033) ────────────────────────────
GATEWAY_ENDPOINT="http://127.0.0.1:${PORT_GATEWAY}"
GATEWAY_CLI_NAME="obo-demo"
OS_CMD=(openshell --gateway "$GATEWAY_CLI_NAME" --gateway-endpoint "$GATEWAY_ENDPOINT")

# Register the gateway with the CLI and make it active, so demo commands can be
# typed as `openshell sandbox exec ...` with no --gateway-endpoint flag. That
# matters on stage: the flag is noise in front of an audience.
#
# This passed --no-tls, which does not exist at v0.0.116, and swallowed the
# error with `|| true`, so registration silently never happened.
register_gateway_cli() {
  if openshell gateway list 2>/dev/null | grep -q "$GATEWAY_CLI_NAME"; then
    openshell gateway select "$GATEWAY_CLI_NAME" >/dev/null 2>&1
    return $?
  fi
  openshell gateway add "$GATEWAY_ENDPOINT" --name "$GATEWAY_CLI_NAME" >/dev/null 2>&1
}

mint_subject_token() {
  if [ -f "$TOKEN_FILE" ]; then
    local remaining
    remaining=$(jwt_seconds_remaining "$(cat "$TOKEN_FILE")")
    if [ "$remaining" -ge 5400 ]; then
      return 0
    fi
    info "Subject token validity low (${remaining}s), minting fresh..."
  fi

  info "Minting subject token..."
  local response token
  response=$(curl -fsS "http://127.0.0.1:${PORT_ISSUER}/demo-subject-token" 2>/dev/null) || {
    actionable_fail "issuer" "Could not reach issuer at port $PORT_ISSUER. Is the container running?"
    return 1
  }
  token=$(printf '%s' "$response" | python3 -c \
    "import sys, json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

  if [ -z "$token" ]; then
    actionable_fail "issuer" "Issuer responded but access_token was empty"
    return 1
  fi

  printf '%s' "$token" > "$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"
}

# Turn on the agent-facing policy proposal surface.
#
# The supervisor reads this once at startup, before it installs the skill, so
# it has to be set before `sandbox create` rather than on a live sandbox. It is
# gateway state, which teardown removes with the state dir, so setting it here
# is what makes it survive the teardown-then-bring-up rebuild.
#
# What it buys the demo is `/etc/openshell/skills/policy_advisor.md` inside the
# sandbox plus a live `policy.local`. It does NOT add `next_steps` to the deny
# bodies this demo produces: that richer shape comes from the REST rules
# inspector, and both of our denials are refused earlier, at the endpoint gate.
setup_policy_advisor() {
  info "Enabling the agent policy proposal surface..."
  "${OS_CMD[@]}" settings set --global \
    --key agent_policy_proposals_enabled --value true --yes >/dev/null 2>&1 || \
    warn "Could not enable agent_policy_proposals_enabled; the policy advisor skill will be absent"
}

setup_provider() {
  local profile_file="${DEMO_DIR}/providers/protected-service.yaml"
  local profile_id="obo-demo"
  local provider_name="$DELEGATION_PROVIDER"

  if [ ! -f "$profile_file" ]; then
    warn "Provider profile not yet written: $profile_file"
    return 0
  fi

  info "Setting up provider profile and credentials..."

  "${OS_CMD[@]}" provider profile delete "$profile_id" >/dev/null 2>&1 || true
  "${OS_CMD[@]}" provider profile import -f "$profile_file" >/dev/null 2>&1

  local subject_token
  subject_token=$(cat "$TOKEN_FILE")

  # `provider delete` refuses while the sandbox still references the provider,
  # so delete-then-create leaves the freshly minted subject token unwritten and
  # the demo runs on the previous one. Update in place when it already exists.
  if "${OS_CMD[@]}" provider get "$provider_name" >/dev/null 2>&1; then
    "${OS_CMD[@]}" provider update "$provider_name" \
      --credential "subject_token=${subject_token}" >/dev/null 2>&1
  else
    "${OS_CMD[@]}" provider create --name "$provider_name" --type "$profile_id" \
      --credential "subject_token=${subject_token}" >/dev/null 2>&1
  fi
}

create_sandbox() {
  # Check if sandbox already exists
  if "${OS_CMD[@]}" sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
    add_readiness "sandbox:$SANDBOX_NAME" "ready"
    return
  fi

  info "Creating sandbox: $SANDBOX_NAME"
  # The policy is supplied at creation, not patched afterwards. Several policy
  # sections (process identity, and any read_only path being removed) are
  # startup-only and the gateway rejects changing them on a live sandbox, so
  # create-then-apply can never converge.
  local policy_file="${DEMO_DIR}/policy/sandbox-policy.yaml"
  local policy_args=()
  [ -f "$policy_file" ] && policy_args=(--policy "$policy_file")

  # The main process must stay alive. Every beat runs `sandbox exec` into this
  # sandbox, so it has to persist for the whole demo. A one-shot command exits
  # during provisioning and the sandbox enters the error phase with
  # "MainProcessExited", which fails creation even with --keep.
  # Attach the inference provider alongside the delegation provider, and for
  # Vertex add the non-secret targeting environment. Two providers, two
  # different custody stories: obo-demo mints a delegated token per request,
  # the inference provider supplies a credential the agent never holds.
  local inference_args=()
  [ -n "${INFERENCE_PROVIDER:-}" ] && inference_args=(--provider "$INFERENCE_PROVIDER")

  local env_args=()
  while IFS= read -r line; do
    [ -n "$line" ] && env_args+=("$line")
  done < <(inference_sandbox_env_args)

  "${OS_CMD[@]}" sandbox create --name "$SANDBOX_NAME" --provider "$DELEGATION_PROVIDER" \
    "${inference_args[@]}" "${env_args[@]}" \
    "${policy_args[@]}" \
    --keep --detach --no-tty -- sleep infinity >"${STATE_DIR}/sandbox-create.log" 2>&1 || {
      add_readiness "sandbox:$SANDBOX_NAME" "failed" \
        "sandbox creation failed, see ${STATE_DIR}/sandbox-create.log"
      return
    }

  # Phase "Ready" is not sufficient. A sandbox whose JWT has expired still
  # reports Ready while every exec fails with "relay open timed out", so prove
  # the relay actually works instead of trusting the phase. Every beat runs
  # exec, so a sandbox that cannot exec is useless regardless of its phase.
  if ! "${OS_CMD[@]}" sandbox exec --name "$SANDBOX_NAME" --no-tty -- true \
      >"${STATE_DIR}/sandbox-exec-check.log" 2>&1; then
    add_readiness "sandbox:$SANDBOX_NAME" "failed" \
      "phase Ready but exec fails, see ${STATE_DIR}/sandbox-exec-check.log"
    return
  fi

  add_readiness "sandbox:$SANDBOX_NAME" "ready"
}

register_sandbox_spire() {
  local spire_dir="${OPENSHELL_WORKTREE}/examples/spiffe-token-exchange-demo/podman/spire"

  # Get sandbox ID
  local sandbox_id
  sandbox_id=$("${OS_CMD[@]}" sandbox list --output json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
sandboxes = data if isinstance(data, list) else data.get('sandboxes', [])
for s in sandboxes:
    if s.get('name') == '${SANDBOX_NAME}':
        print(s.get('id', ''))
        break
" 2>/dev/null || echo "")

  if [ -z "$sandbox_id" ]; then
    warn "Could not resolve sandbox ID for $SANDBOX_NAME; SPIRE registration skipped"
    return
  fi

  info "Registering SPIRE entry for sandbox: $sandbox_id"
  if ! SANDBOX_SELECTORS="docker:label:openshell.managed:true docker:label:openshell.ai/sandbox-id:${sandbox_id}" \
    bash "$spire_dir/register-sandbox.sh" "$sandbox_id" >/dev/null 2>&1; then
    warn "SPIRE registration for sandbox $sandbox_id failed (may already exist)"
  fi
}

apply_sandbox_policy() {
  local policy_file="${DEMO_DIR}/policy/sandbox-policy.yaml"
  if [ ! -f "$policy_file" ]; then
    warn "Sandbox policy not yet written: $policy_file"
    return 0
  fi

  # The policy is applied at sandbox creation (see create_sandbox), because
  # process identity and read_only removals are startup-only and the gateway
  # refuses them on a live sandbox. Here we only confirm a policy is in effect,
  # rather than re-applying one and failing on fields that cannot change.
  info "Verifying sandbox policy is in effect..."
  if ! "${OS_CMD[@]}" policy get "$SANDBOX_NAME" \
      >"${STATE_DIR}/policy-get.log" 2>&1; then
    actionable_fail "sandbox-policy" \
      "No policy in effect on $SANDBOX_NAME. See ${STATE_DIR}/policy-get.log"
    add_readiness "sandbox-policy" "failed" "no policy in effect"
    return
  fi
  if ! grep -qi "effective" "${STATE_DIR}/policy-get.log"; then
    actionable_fail "sandbox-policy" \
      "Policy on $SANDBOX_NAME is not effective. See ${STATE_DIR}/policy-get.log"
    add_readiness "sandbox-policy" "failed" "policy not effective"
    return
  fi
  add_readiness "sandbox-policy" "ready"
}

# ── Inference provider (T051) ────────────────────────────────────
setup_inference_provider() {
  INFERENCE_MODE="$(resolve_inference_mode)"

  case "$INFERENCE_MODE" in
    none)
      warn "No inference backend (set ANTHROPIC_API_KEY, or provide gcloud ADC for Vertex)"
      warn "Beats needing the agent will fall back to their --curl paths"
      INFERENCE_PROVIDER=""
      return 0
      ;;

    apikey)
      # Credential passed on the command line, never written to disk (FR-031).
      info "Inference: Anthropic API key"
      INFERENCE_PROVIDER="claude-code"
      "${OS_CMD[@]}" provider delete "$INFERENCE_PROVIDER" >/dev/null 2>&1 || true
      if ! "${OS_CMD[@]}" provider create --name "$INFERENCE_PROVIDER" --type "claude-code" \
          --credential "api_key=${ANTHROPIC_API_KEY}" \
          >"${STATE_DIR}/inference-provider.log" 2>&1; then
        warn "API key provider setup failed, see ${STATE_DIR}/inference-provider.log"
        INFERENCE_PROVIDER=""
      fi
      ;;

    vertex)
      # `--from-gcloud-adc` reads the ADC file itself, so the client_secret and
      # refresh_token never pass through this script, the shell history, or any
      # log. The CLI looks under $HOME, which inside the VM is /var/home/core,
      # so point HOME at the account that actually owns the credentials.
      info "Inference: Google Vertex AI (project ${VERTEX_PROJECT_ID:-<unresolved>}, region ${VERTEX_REGION})"
      if [ ! -f "$GCLOUD_ADC_FILE" ]; then
        warn "gcloud ADC not found at $GCLOUD_ADC_FILE"
        warn "Run 'gcloud auth application-default login', or set GCLOUD_ADC_HOME"
        INFERENCE_PROVIDER=""
        return 0
      fi
      # Without a project the gateway cannot build the Vertex base URL, and the
      # provider would be created in a state that only fails later, at the first
      # inference call. Refuse here instead.
      if [ -z "${VERTEX_PROJECT_ID:-}" ]; then
        warn "No GCP project: none set in the active gcloud config under $GCLOUD_ADC_HOME"
        warn "Run 'gcloud config set project <id>', or export VERTEX_PROJECT_ID"
        INFERENCE_PROVIDER=""
        return 0
      fi

      # No profile import here: `google-vertex-ai` ships as a builtin profile
      # and the gateway refuses to overwrite a builtin, so importing the file
      # from the worktree can only ever fail and write noise into the log.

      # providers_v2_enabled is deliberately NOT set. It folds a provider
      # profile's declared endpoints into the sandbox policy, which this demo
      # does not need: sandbox-policy.yaml names every destination itself, and
      # inference.local bypasses the network supervisor entirely rather than
      # being matched against policy. Verified by running the whole demo with
      # it off.

      # The provider carries the project and region as config, not as sandbox
      # env: the gateway builds the Vertex base URL from them at route time.
      INFERENCE_PROVIDER="obo-vertex"
      local vertex_config=(
        --config "VERTEX_AI_PROJECT_ID=${VERTEX_PROJECT_ID}"
        --config "VERTEX_AI_REGION=${VERTEX_REGION}"
      )
      # `provider delete` refuses while a sandbox still references the provider,
      # so a re-run updates in place rather than treating delete-then-create as
      # guaranteed. Without this the create below fails with "already exists"
      # and the demo silently keeps a provider that has no config.
      if "${OS_CMD[@]}" provider get "$INFERENCE_PROVIDER" >/dev/null 2>&1; then
        if ! HOME="$GCLOUD_ADC_HOME" "${OS_CMD[@]}" provider update "$INFERENCE_PROVIDER" \
            "${vertex_config[@]}" \
            >>"${STATE_DIR}/inference-provider.log" 2>&1; then
          warn "Vertex provider update failed, see ${STATE_DIR}/inference-provider.log"
          INFERENCE_PROVIDER=""
          return 0
        fi
      elif ! HOME="$GCLOUD_ADC_HOME" "${OS_CMD[@]}" provider create \
          --name "$INFERENCE_PROVIDER" --type "google-vertex-ai" \
          --from-gcloud-adc "${vertex_config[@]}" \
          >>"${STATE_DIR}/inference-provider.log" 2>&1; then
        warn "Vertex provider setup failed, see ${STATE_DIR}/inference-provider.log"
        INFERENCE_PROVIDER=""
        return 0
      fi

      # Point `inference.local` at the provider. `--no-verify` because the
      # probe does not match the rawPredict path for the `global` region.
      if ! "${OS_CMD[@]}" inference set --provider "$INFERENCE_PROVIDER" \
          --model "$VERTEX_MODEL" --no-verify \
          >>"${STATE_DIR}/inference-provider.log" 2>&1; then
        warn "Inference routing setup failed, see ${STATE_DIR}/inference-provider.log"
        INFERENCE_PROVIDER=""
      fi
      ;;
  esac
}

# Point the agent at `inference.local` rather than at Vertex directly.
#
# Setting CLAUDE_CODE_USE_VERTEX makes Claude Code talk to Vertex itself and
# hunt for GCP credentials through ADC and the metadata service, which the
# sandbox deliberately does not expose, so it fails with token_unavailable.
# The gateway terminates `inference.local`, strips the placeholder key below,
# and injects the real short-lived GCP token on the way out, which is the
# property the talk is actually claiming.
inference_sandbox_env_args() {
  [ "${INFERENCE_MODE:-none}" = "vertex" ] || return 0
  printf '%s\n' \
    "--env" "ANTHROPIC_BASE_URL=https://inference.local" \
    "--env" "ANTHROPIC_API_KEY=unused"
}

# ── MCP config rendering (T052) ─────────────────────────────────
render_mcp_config() {
  local template="${DEMO_DIR}/agent/mcp-config.json.template"
  local output="${DEMO_DIR}/agent/mcp-config.json"
  if [ -f "$template" ]; then
    sed \
      -e "s|__MCP_HOST__|${MCP_HOST}|g" \
      -e "s|__MCP_PORT__|8080|g" \
      "$template" > "$output"
  fi
}

# ── Readiness report (T018, T019) ────────────────────────────────
report_readiness() {
  echo ""
  printf "${C_BOLD}Component Readiness${C_RESET}\n"
  echo ""

  for entry in "${READINESS[@]}"; do
    IFS='|' read -r component state detail <<< "$entry"
    readiness_row "$component" "$state" "$detail"
  done

  echo ""

  # Credential validity (FR-034, T019)
  local cred_remaining=0
  if [ -f "$TOKEN_FILE" ]; then
    cred_remaining=$(jwt_seconds_remaining "$(cat "$TOKEN_FILE")")
  fi

  if $ALL_READY && [ "$cred_remaining" -ge 5400 ]; then
    local mins=$((cred_remaining / 60))
    printf "${C_GREEN}${C_BOLD}Ready${C_RESET} (credential validity: %d minutes)\n" "$mins"
    exit 0
  elif $ALL_READY && [ "$cred_remaining" -gt 0 ]; then
    printf "${C_YELLOW}${C_BOLD}Components ready but credential validity low${C_RESET}: %d seconds remaining (need 5400)\n" "$cred_remaining"
    printf "Re-run bring-up.sh to mint fresh tokens\n"
    exit 1
  else
    printf "${C_RED}${C_BOLD}Not ready${C_RESET}\n"
    exit 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────
main() {
  info "OBO Demo bring-up"

  # Prerequisite check: openshell CLI must be on PATH (F-03)
  if ! command -v openshell >/dev/null 2>&1; then
    fail "openshell CLI not found on PATH. Install it before running bring-up."
    exit 1
  fi

  ensure_network

  # SPIRE infrastructure (T013)
  start_spire

  # Demo services (T014)
  start_issuer
  start_protected_service

  # MCP server (T045)
  start_mcp_server

  # Gateway (T015)
  start_gateway

  # Gateway CLI registration
  register_gateway_cli || warn "Gateway CLI registration failed"

  # Subject token (T019)
  mint_subject_token || warn "Subject token minting failed"

  # Agent policy proposal surface. Must precede sandbox creation: the
  # supervisor reads the setting once at startup.
  setup_policy_advisor

  # Provider profile and credentials (T033)
  setup_provider || warn "Provider setup failed"

  # Inference provider (T051). Must precede sandbox creation: the provider is
  # attached at create time, and for Vertex the sandbox also needs the
  # non-secret targeting environment set on the same command.
  setup_inference_provider

  # Sandbox (T016)
  create_sandbox
  register_sandbox_spire

  # Now that the gateway is up and this run's sandbox entry exists, drop the
  # entries left behind by previous runs.
  prune_orphaned_sandbox_entries

  # Sandbox policy (T045)
  apply_sandbox_policy

  # MCP config rendering (T052)
  render_mcp_config

  # Readiness report (T018)
  report_readiness
}

main "$@"
