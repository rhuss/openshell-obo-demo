#!/usr/bin/env bash
# Semi-automatic stage driver.
#
# Types each command out at a real prompt, waits for you to press a key, then
# runs it for real. The audience sees the actual openshell command, not a
# script: nothing is hidden, the pacing is yours, and there is nothing to
# mistype in front of people.
#
#   bash demo/walkthrough.sh short      # the five-minute version
#   bash demo/walkthrough.sh            # act 0, then all five beats (full)
#   bash demo/walkthrough.sh act0       # just the live setup
#   bash demo/walkthrough.sh 3          # just beat 3
#   bash demo/walkthrough.sh 3 4 5      # a subset, in order
#
# Env:
#   TYPE_SPEED=0.012   seconds per character
#   DEMO_AUTO=1        no key waits, run straight through (for rehearsal/CI)\n#\n# At any pause: any key runs the command, `s` opens a shell with the demo\n# environment (SID, TOKEN, MCP, gateway endpoint). Ctrl-D returns.
#
# Run it inside the VM, after bring-up and after the OpenShell layer reset
# described in demo/STAGE.md.

set -uo pipefail

TYPE_SPEED="${TYPE_SPEED:-0.012}"
DEMO_AUTO="${DEMO_AUTO:-0}"
# bat pages through less when stdout is a terminal, which is what we want on
# stage and exactly what we do not want in an unattended rehearsal run.
[ "$DEMO_AUTO" = 1 ] && export BAT_PAGER=cat

DIM=$'\033[2m'; BOLD=$'\033[1m'; GREEN=$'\033[32m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
PROMPT="${GREEN}➜${RESET} "

# Values come from demo/env.sh so the commands on screen show variable names
# rather than a GCP project id and a home directory. Source it yourself before
# the demo if you want them set in your own shell too.
_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=demo/env.sh
. "$_root/demo/env.sh"
CONTAINER_SPIRE_SERVER="${CONTAINER_SPIRE_SERVER:-openshell-spiffe-demo-spire-server}"

_type() {
  local s="$1" i
  for ((i = 0; i < ${#s}; i++)); do
    printf '%s' "${s:i:1}"
    sleep "$TYPE_SPEED"
  done
}

# Wait for a keypress. Reads the terminal directly so it still works when
# stdin is a pipe.
#
# Shows a faint marker while waiting and erases it on the keypress. Without it
# the script looks hung: commands that draw a progress spinner (sandbox create)
# leave the cursor mid-line, and a silent wait after that is indistinguishable
# from a stuck command.
# Wait at a pause. Any key advances; `s` drops into a shell first.
#
# $1, when given, is the command already typed on screen. After the shell exits
# the screen has moved on, so it gets reprinted at a fresh prompt: otherwise you
# come back to a bare cursor with no idea what is about to run.
_key() {
  [ "$DEMO_AUTO" = 1 ] && return 0
  [ -r /dev/tty ] || return 0
  local pending="${1:-}" k
  while :; do
    # Save the cursor, draw the marker, then restore and clear only from there.
    # A bare \r\033[K would wipe the whole line, taking the command with it.
    printf '%b' "\033[s${DIM}  ⏎${RESET}"
    IFS= read -rsn1 k </dev/tty
    printf '\033[u\033[K'
    case "$k" in
      s|S)
        echo
        printf '%b\n' "${DIM}── shell · ctrl-d to return ──${RESET}"
        # Hand over the variables the demo built. They are set by eval in this
        # shell rather than exported, so a bare `bash -i` would not see them.
        SID="${SID:-}" TOKEN="${TOKEN:-}" MCP="${MCP:-}" \
        OPENSHELL_GATEWAY_ENDPOINT="$OPENSHELL_GATEWAY_ENDPOINT" \
        PS1="$(printf '%b' "${DIM}(demo)${RESET} $ ")" \
          bash --norc -i </dev/tty >/dev/tty 2>&1
        printf '%b\n' "${DIM}── back ──${RESET}"
        [ -n "$pending" ] && printf '%b%s' "$PROMPT" "$pending"
        ;;
      *) return 0 ;;
    esac
  done
}

# Typed shell comment. Orients the audience without breaking the illusion.
pc() {
  printf '%b' "$PROMPT"
  _type "${DIM}# $1${RESET}"
  echo
  _key
}

# Type a command, wait, then run it for real.
pe() {
  printf '%b' "$PROMPT"
  _type "$1"
  _key "$1"
  echo
  eval "$1"
  # Reset attributes only. Clearing the line would eat output that does not end
  # in a newline, which is most of the JSON denials. And no exit code: these
  # commands are *supposed* to fail, and "(exit 2)" makes a working
  # demonstration look broken.
  printf '\033[0m'
  echo
  return 0
}

# The sandbox batches audit records and flushes them to the gateway, so a
# refusal that just happened is not in `openshell logs` yet. Wait for it before
# typing the command that looks for it: an empty result at a beat's punchline
# reads as a broken demo when the denial actually worked fine.
# Clear the OpenShell layer so Act 0 genuinely creates everything. Without this
# a second run dies on "provider profile 'obo-demo' already exists", which is a
# nasty thing to discover mid-rehearsal. Infrastructure and SPIRE are untouched.
# Pretty-print a slice of a file. bat if it is installed (static binary in
# ~/.local/bin on the demo VM), otherwise numbered plain text, so this still
# works on a machine without it.
PAGER_CMD=""
if command -v bat >/dev/null 2>&1; then
  PAGER_CMD="bat --style=numbers --paging=never --theme=ansi"
fi
_show() {
  local file="$1" range="$2"
  if [ -n "$PAGER_CMD" ]; then
    $PAGER_CMD --line-range "$range" "$file"
  else
    sed -n "${range%:*},${range#*:}p" "$file" | cat -n
  fi
}

_reset_layer() {
  local out rc
  # Deletion is asynchronous: the call returns while the sandbox sits in phase
  # Deleting and still appears in `sandbox list`. Retry the delete and wait for
  # it to actually disappear.
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    openshell sandbox list 2>/dev/null | grep -q obo-demo || break
    out="$(openshell sandbox delete obo-demo 2>&1)"; rc=$?
    if [ $rc -ne 0 ] && ! printf '%s' "$out" | grep -qi "not found"; then
      printf '%b\n' "${DIM}  sandbox delete: ${out}${RESET}" >&2
    fi
    sleep 2
  done

  # Refuse to continue rather than letting `sandbox create` fail later with
  # "already exists", which reads like a bug in the demo rather than leftover
  # state from the previous run.
  if openshell sandbox list 2>/dev/null | grep -q obo-demo; then
    printf '%b\n' "${BOLD}Could not remove the existing sandbox.${RESET}" >&2
    printf '  openshell sandbox list\n' >&2
    printf '  openshell sandbox delete obo-demo\n' >&2
    printf '  or rebuild: bash demo/teardown.sh && bash demo/bring-up.sh\n' >&2
    return 1
  fi

  openshell inference delete >/dev/null 2>&1
  openshell provider delete obo-user-token obo-demo obo-vertex >/dev/null 2>&1
  openshell provider profile delete obo-demo >/dev/null 2>&1

  # Drop leftover sandbox SPIFFE entries. No sandbox exists at this point, so
  # every one of them is an orphan from an earlier run. Without this, the
  # identity step shows a list of dead entries and the point it is making --
  # "this sandbox has an identity" -- is buried in noise.
  local ids
  ids="$(podman exec "$CONTAINER_SPIRE_SERVER" /opt/spire/bin/spire-server entry show \
        -socketPath /run/spire/server/private/api.sock -output json 2>/dev/null \
        | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for e in d.get("entries", []):
    if e.get("spiffe_id",{}).get("path","").startswith("/openshell/sandbox/") and e.get("id"):
        print(e["id"])
' 2>/dev/null)"
  local id
  for id in $ids; do
    podman exec "$CONTAINER_SPIRE_SERVER" /opt/spire/bin/spire-server entry delete \
      -socketPath /run/spire/server/private/api.sock -entryID "$id" >/dev/null 2>&1
  done
  return 0
}

_await_record() {
  local pat="$1" deadline=$((SECONDS + 25))
  while [ "$SECONDS" -lt "$deadline" ]; do
    openshell logs obo-demo -n 300 --source sandbox 2>/dev/null \
      | grep -F DENIED | grep -qF -- "$pat" && return 0
    sleep 2
  done
  return 0
}


act0() {
  printf '%b' "${DIM}  preparing a clean slate...${RESET}"
  _reset_layer || return 1
  printf '\r\033[K'
  pc "gateway endpoint, project, region. no flags on anything below"
  pe "source demo/env.sh"

  pc "the user's token. here from a demo issuer, in your world from your IdP"
  pe "TOKEN=\$(curl -fsS \$OBO_ISSUER_URL/demo-subject-token | jq -r .access_token)"

  pc "this is what is in it"
  pe "echo \"\$TOKEN\" | cut -d. -f2 | base64 -d | jq"

  pc "this profile declares the token exchange. a declaration, not code"
  pe "openshell provider profile import -f demo/providers/protected-service.yaml"

  pc "the whole thing. scroll it, q to quit"
  pe "bat demo/providers/protected-service.yaml"

  pc "hand the user's token to the gateway once. it never enters the sandbox"
  pe "openshell provider create --name obo-user-token --type obo-demo --credential subject_token=\"\$TOKEN\""

  pc "inference credential: reads the ADC file itself, never through this shell"
  pe "HOME=\$GCLOUD_ADC_HOME openshell provider create --name obo-vertex --type google-vertex-ai --from-gcloud-adc --config VERTEX_AI_PROJECT_ID=\$VERTEX_PROJECT_ID --config VERTEX_AI_REGION=\$VERTEX_REGION"

  pc "the agent will talk to inference.local; the gateway holds the real key"
  pe "openshell inference set --provider obo-vertex --model \$VERTEX_MODEL --no-verify"

  pc "two credentials, and the agent never holds either"
  pc "policy and env are set only here, at creation"
  # --detach is load-bearing: without it the CLI attaches to the main process
  # (`sleep infinity`) and never returns when stdout is a terminal. It looks
  # like the demo has hung right after "Created sandbox".
  pc "ANTHROPIC_API_KEY=unused gets the agent past its own login check, nothing more"
  pe "openshell sandbox create --name obo-demo --provider obo-user-token --provider obo-vertex --env ANTHROPIC_BASE_URL=https://inference.local --env ANTHROPIC_API_KEY=unused --policy demo/policy/sandbox-policy.yaml --keep --detach --no-tty -- sleep infinity"

  pc "ask the gateway which id it gave this sandbox"
  pe "SID=\$(openshell sandbox list --output json | jq -r '.[]|select(.name==\"obo-demo\")|.id')"
  # The assignment prints nothing. Show the value: the identity is about to be
  # built from it, and the same uuid reappears in the act chain later.
  pc "that uuid is the sandbox. watch where it turns up later"
  pe "echo \$SID"
  pc "register it with SPIRE: this id, issued by that agent"
  pc "the selectors are container labels. SPIRE hands the identity only to a container that carries them"
  pc "on kubernetes you do not type this: the SPIRE controller manager registers pods for you"
  pe "podman exec openshell-spiffe-demo-spire-server /opt/spire/bin/spire-server entry create -socketPath /run/spire/server/private/api.sock -parentID spiffe://openshell.local/openshell/spire-agent/demo -spiffeID spiffe://openshell.local/openshell/sandbox/\$SID -selector docker:label:openshell.managed:true -selector docker:label:openshell.ai/sandbox-id:\$SID"
}

beat1() {
  pc "a destination nobody authorised"
  pe "openshell sandbox exec --name obo-demo -- curl -sS http://example.com/"
  pc "nothing was blocklisted. example.com was never on the list"
  _await_record "example.com"
  pe "openshell logs obo-demo -n 200 --source sandbox | grep DENIED | grep example.com | tail -1"
}

beat2() {
  pc "the identity we just registered, as SPIRE sees it"
  pe "podman exec openshell-spiffe-demo-spire-server /opt/spire/bin/spire-server entry show -socketPath /run/spire/server/private/api.sock | grep -A1 sandbox"
  pc "used on its behalf. it cannot touch it:"
  pe "openshell sandbox exec --name obo-demo -- ls /run/spire"
}

beat3() {
  pc "a service that demands a real credential"
  pe "openshell sandbox exec --name obo-demo -- curl -sS http://alpha.default.svc.cluster.local:8080/"
  pc "it worked. the service knows the user AND the workload that asked"
  pc "here is the credential it was given. note where I have to run this from:"
  pc "a unix socket inside the issuer. no tcp port, so the sandbox cannot reach it"
  pe "podman exec openshell-spiffe-demo-issuer curl -s --unix-socket /tmp/debug.sock localhost/debug/last-token | jq '.tokens[0].claims|{sub,act}'"
  pc "sub is the user. act reads outward: the sandbox acted, the gateway acted for it"
  pc "so what does the agent itself hold?"
  pe "openshell sandbox exec --name obo-demo -- env | grep openshell:resolve"
  pc "placeholders. only the egress proxy can turn one into a credential"
}

beat4() {
  pc "first, everything the agent is told about tools. one server, two tools"
  pe "echo \$MCP | jq"
  pc "--strict-mcp-config: use that server and nothing the machine might have lying around"
  pc "--allowedTools: I pre-approve BOTH, so the agent will not stop to ask me"
  pc "which leaves exactly one thing that can still refuse: the platform"
  pe "openshell sandbox exec --name obo-demo -- claude --print --mcp-config \"\$MCP\" --strict-mcp-config --allowedTools='mcp__obo-demo__weather_lookup,mcp__obo-demo__database_query' 'Use weather_lookup for Warsaw, then database_query to run SELECT * FROM users. Report exactly what happened with each.'"
}

beat5() {
  pc "same MCP host the agent just used. now with curl"
  pe "openshell sandbox exec --name obo-demo -- curl -sS http://mcp.default.svc.cluster.local:8080/healthz"
  pc "the agent reached that exact host and port a moment ago. curl cannot"
  pc "the caller is told only policy_denied. the reason lives in the audit record:"
  _await_record "/usr/bin/curl"
  pe "openshell logs obo-demo -n 200 --source sandbox | grep DENIED | grep curl | tail -1"
}

# ── Short form: the five-minute version ────────────────────────────────────
#
# Six commands. Creates the sandbox, shows the agent holds nothing usable, then
# tool-level and binary-level refusal on the same MCP host, then delegation in
# one line. No SPIRE or SPIFFE machinery on screen: the identity registration
# happens quietly below, which is also what Kubernetes does for you.
short() {
  _reset_layer || return 1

  pc "the user's token. here from a demo issuer, in your world from your IdP"
  pe "TOKEN=\$(curl -fsS \$OBO_ISSUER_URL/demo-subject-token | jq -r .access_token)"

  pc "this profile declares the token exchange. a declaration, not code"
  pe "openshell provider profile import -f demo/providers/protected-service.yaml"

  pc "hand the user's token to the gateway once. it never enters the sandbox"
  pe "openshell provider create --name obo-user-token --type obo-demo --credential subject_token=\"\$TOKEN\""

  pc "inference credential: reads the ADC file itself, never through this shell"
  pe "HOME=\$GCLOUD_ADC_HOME openshell provider create --name obo-vertex --type google-vertex-ai --from-gcloud-adc --config VERTEX_AI_PROJECT_ID=\$VERTEX_PROJECT_ID --config VERTEX_AI_REGION=\$VERTEX_REGION"

  pc "the agent will talk to inference.local; the gateway holds the real key"
  pe "openshell inference set --provider obo-vertex --model \$VERTEX_MODEL --no-verify"

  pc "one sandbox. two credentials attached, neither of them for the agent"
  pc "policy and env are set only here, at creation"
  pe "openshell sandbox create --name obo-demo --provider obo-user-token --provider obo-vertex --env ANTHROPIC_BASE_URL=https://inference.local --env ANTHROPIC_API_KEY=unused --policy demo/policy/sandbox-policy.yaml --keep --detach --no-tty -- sleep infinity"

  pc "and it gets a SPIFFE identity. on kubernetes the SPIRE controller manager"
  pc "registers that for you when the pod appears, so I do it off-screen here"

  # Identity registration, not shown. On Kubernetes the SPIRE controller
  # manager does exactly this when the pod appears.
  local sid
  sid="$(openshell sandbox list --output json | jq -r '.[]|select(.name=="obo-demo")|.id')"
  podman exec "$CONTAINER_SPIRE_SERVER" /opt/spire/bin/spire-server entry create \
    -socketPath /run/spire/server/private/api.sock \
    -parentID spiffe://openshell.local/openshell/spire-agent/demo \
    -spiffeID "spiffe://openshell.local/openshell/sandbox/$sid" \
    -selector docker:label:openshell.managed:true \
    -selector "docker:label:openshell.ai/sandbox-id:$sid" >/dev/null 2>&1

  pc "so what does the agent actually hold?"
  pe "openshell sandbox exec --name obo-demo -- env | grep openshell:resolve"
  pc "one placeholder. only the proxy on the way out can turn that into a token"
  pc "and the delegated credential is not even here: it is minted per request, at the proxy"

  pc "now the agent. I pre-approve BOTH tools, so nothing but the platform can refuse"
  pe "openshell sandbox exec --name obo-demo -- claude --print --mcp-config \"\$MCP\" --strict-mcp-config --allowedTools='mcp__obo-demo__weather_lookup,mcp__obo-demo__database_query' 'Use weather_lookup for Warsaw, then database_query to run SELECT * FROM users. Report exactly what happened with each.'"
  pc "one tool through, one refused. same server, same port, same connection"

  # Optional, skip when running tight. The advisor surface is enabled by
  # bring-up; this shows the agent was handed a way to ask, rather than just
  # being told no.
  pc "and a refusal is not a dead end. the sandbox ships the agent a skill:"
  pe "openshell sandbox exec --name obo-demo -- ls /etc/openshell/skills/"
  pc "it documents policy.local, an API inside the sandbox for proposing a rule"
  pc "proposals go to a review queue. the agent asks, a human still decides"

  pc "the agent just reached that host. now the same host with curl"
  pe "openshell sandbox exec --name obo-demo -- curl -sS http://mcp.default.svc.cluster.local:8080/healthz"
  pc "the caller is told only policy_denied. the reason is in the audit record:"
  _await_record "/usr/bin/curl"
  pe "openshell logs obo-demo -n 200 --source sandbox | grep DENIED | grep curl | tail -1"
  pc "it names the program. not the destination, not the user"

  pc "last one: a service that demands a real credential"
  pe "openshell sandbox exec --name obo-demo -- curl -sS http://alpha.default.svc.cluster.local:8080/"
  pc "sub is the user. azp is the sandbox that asked. minted for this request, gone in five minutes"
}

run_one() {
  case "$1" in
    reset) _reset_layer && echo "OpenShell layer cleared." ;;
    short) short ;;
    act0|0) act0 ;;
    1) beat1 ;; 2) beat2 ;; 3) beat3 ;; 4) beat4 ;; 5) beat5 ;;
    *) printf 'unknown step: %s (use short, reset, act0, 1..5)\n' "$1" >&2; return 1 ;;
  esac
}

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

if [ $# -eq 0 ]; then
  act0; beat1; beat2; beat3; beat4; beat5
else
  for step in "$@"; do run_one "$step" || exit 1; done
fi

echo
printf '%b\n' "${DIM}— end —${RESET}"
