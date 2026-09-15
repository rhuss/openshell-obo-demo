# Source before running the walkthrough:
#
#     source demo/env.sh
#
# Keeps concrete values off the screen. The walkthrough can then show
#
#     --config VERTEX_AI_PROJECT_ID=$VERTEX_PROJECT_ID
#
# instead of your GCP project name, which is what an audience and any recording
# would otherwise see.
#
# Nothing is hardcoded here: the project comes from your active gcloud
# configuration and the ADC home is probed for the credentials file, so this
# file carries no personal values and is safe to commit. Override any of them by
# exporting it before sourcing.

_obo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# lib/common.sh sets `set -euo pipefail`. That must not leak into an interactive
# shell, where a single failed command would close the terminal mid-demo, so
# read the derived values out of a subshell rather than sourcing it here.
eval "$(
  bash -c '
    . "'"$_obo_root"'/demo/lib/common.sh" >/dev/null 2>&1
    printf "_obo_gateway=%q\n"    "http://127.0.0.1:$PORT_GATEWAY"
    printf "OBO_ISSUER_URL=%q\n"  "http://127.0.0.1:$PORT_ISSUER"
    printf "GCLOUD_ADC_HOME=%q\n" "$GCLOUD_ADC_HOME"
    printf "VERTEX_PROJECT_ID=%q\n" "$VERTEX_PROJECT_ID"
    printf "VERTEX_REGION=%q\n"   "$VERTEX_REGION"
    printf "VERTEX_MODEL=%q\n"    "$VERTEX_MODEL"
    printf "MCP_HOST=%q\n"        "$MCP_HOST"
    printf "PROTECTED_HOST=%q\n"  "$PROTECTED_HOST"
  '
)"

# Every openshell command picks this up, so none of them needs a flag.
export OPENSHELL_GATEWAY_ENDPOINT="${OPENSHELL_GATEWAY_ENDPOINT:-$_obo_gateway}"
export GCLOUD_ADC_HOME VERTEX_PROJECT_ID VERTEX_REGION VERTEX_MODEL
export OBO_ISSUER_URL MCP_HOST PROTECTED_HOST

# Ghostty advertises TERM=xterm-ghostty, which the VM's terminfo database does
# not carry, so anything curses-based fails with "unknown terminal type" -- most
# visibly `less`, which is bat's pager, mid-demo. xterm-256color is present in
# the VM and keeps bat's colours. Override by exporting TERM before sourcing.
if ! infocmp "${TERM:-dumb}" >/dev/null 2>&1; then
  export TERM=xterm-256color
fi

# Beat 4 needs this and it is too long to type live.
export MCP="{\"mcpServers\":{\"obo-demo\":{\"type\":\"http\",\"url\":\"http://${MCP_HOST}:8080/\"}}}"

unset _obo_root _obo_gateway

if [ -z "${VERTEX_PROJECT_ID:-}" ]; then
  printf 'demo/env.sh: no GCP project found in the active gcloud config.\n' >&2
  printf '  run `gcloud config set project <id>`, or export VERTEX_PROJECT_ID\n' >&2
fi
