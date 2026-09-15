#!/usr/bin/env bash
# Remove everything the demo created (FR-004).
# Never touches the OpenShell worktree or the presenter's config (FR-030).
# Idempotent: safe on an already clean machine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demo/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

GATEWAY_CLI_NAME="obo-demo"
GATEWAY_ENDPOINT="http://127.0.0.1:${PORT_GATEWAY}"
OS_CMD=(openshell --gateway "$GATEWAY_CLI_NAME" --gateway-endpoint "$GATEWAY_ENDPOINT")

info "OBO Demo teardown"

# Remove sandbox (if openshell is reachable)
if command -v openshell >/dev/null 2>&1; then
  # Sandbox first: a provider still referenced by a sandbox cannot be deleted.
  "${OS_CMD[@]}" sandbox delete "$SANDBOX_NAME" >/dev/null 2>&1 || true
  "${OS_CMD[@]}" inference delete >/dev/null 2>&1 || true
  # obo-vertex and obo-gcloud are created by the inference backends; leaving
  # them behind means the next bring-up reuses a provider this one configured.
  for provider in "obo-user-token" "obo-demo" "claude-code" "obo-vertex" "obo-gcloud"; do
    "${OS_CMD[@]}" provider delete "$provider" >/dev/null 2>&1 || true
  done
  "${OS_CMD[@]}" provider profile delete "obo-demo" >/dev/null 2>&1 || true
  openshell gateway remove "$GATEWAY_CLI_NAME" >/dev/null 2>&1 || true
fi

# Remove all demo containers (reverse order for clean shutdown)
for name in "$CONTAINER_GATEWAY" "$CONTAINER_MCP" "$CONTAINER_PROTECTED" \
            "$CONTAINER_ISSUER" "$CONTAINER_SPIRE_AGENT" \
            "$CONTAINER_OIDC_PROVIDER" "$CONTAINER_SPIRE_SERVER"; do
  if container_exists "$name"; then
    info "Removing $name"
    podman rm -f "$name" >/dev/null 2>&1 || true
  fi
done

# Clean up persistent state.
#
# Must honour OBO_STATE_DIR, and with the same default bring-up uses. This
# hardcoded ${DEMO_DIR}/.state, which on any real run is a directory nothing
# ever wrote to: the demo keeps its state on a VM-native path because SPIRE
# cannot chmod a socket on a macOS-shared filesystem. So teardown reported
# success while leaving every byte of SPIRE state in place, and the README's
# "teardown then bring-up for a clean restart" did not actually restart clean.
# Both locations: the one in use, and the default, which earlier runs wrote to
# before the VM-native path was required. Leaving either behind means a
# subsequent bring-up inherits a SPIRE database and an access-token secret.
for state_dir in "${OBO_STATE_DIR:-}" "${DEMO_DIR}/.state"; do
  [ -n "$state_dir" ] && [ -d "$state_dir" ] || continue
  info "Removing state directory: $state_dir"
  rm -rf "${state_dir:?}"
done

# Clean up generated MCP config
rm -f "${DEMO_DIR}/agent/mcp-config.json"

ok "Teardown complete. Worktree and presenter config untouched."
