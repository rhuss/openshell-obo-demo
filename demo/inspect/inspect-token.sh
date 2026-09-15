#!/usr/bin/env bash
# Inspect the most recently minted delegated credential (FR-014, SC-007).
# Usage:
#   inspect-token.sh              Show the most recent final token
#   inspect-token.sh --phase intermediate   Show the most recent intermediate token
#   inspect-token.sh --chain      Show both phases, delegation chain visible

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=demo/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PHASE="final"
CHAIN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --chain) CHAIN=true; shift ;;
    -h|--help)
      echo "Usage: inspect-token.sh [--phase final|intermediate] [--chain]"
      exit 0 ;;
    *) fail "Unknown argument: $1"; exit 2 ;;
  esac
done

# Fetch tokens from the debug UNIX socket inside the issuer container (C3).
# The debug surface has no TCP port, so podman exec is the only access path.
response=""
if ! response=$(debug_fetch_tokens); then
  fail "inspection surface is down (debug socket in ${CONTAINER_ISSUER} unreachable)"
  exit 1
fi

# Format a single token's claims within the 20-line, 80-char budget (FR-014)
format_token() {
  local json="$1" phase_filter="$2"
  python3 -c "
import json, sys, time

data = json.loads(sys.argv[1])
tokens = data.get('tokens', [])
phase = sys.argv[2]
match = [t for t in tokens if t.get('phase') == phase]
if not match:
    print('no ' + phase + ' token available, run a beat first')
    sys.exit(1)

t = match[0]
claims = t['claims']
now = int(time.time())
exp = claims.get('exp', 0)
remaining = exp - now
if remaining > 0:
    mins, secs = divmod(remaining, 60)
    exp_str = f'in {mins}m{secs:02d}s'
else:
    exp_str = 'EXPIRED'

print(f'  phase  {t[\"phase\"]}')
print(f'  sub    {claims[\"sub\"]}')

act = claims.get('act')
if act:
    print(f'  act    sub  {act[\"sub\"]}')
    inner = act.get('act')
    if inner:
        print(f'         act  sub  {inner[\"sub\"]}')
        deeper = inner.get('act')
        if deeper:
            print(f'              act  sub  {deeper[\"sub\"]}')

aud = claims.get('aud', [])
if isinstance(aud, list):
    aud = ', '.join(aud)
print(f'  aud    {aud}')

scope = claims.get('scope', '')
if scope:
    print(f'  scope  {scope}')

print(f'  exp    {exp_str}')
" "$json" "$phase_filter"
}

if $CHAIN; then
  echo ""
  printf "${C_BOLD}Delegation chain${C_RESET}\n"
  echo ""
  printf "${C_DIM}Phase 1: gateway exchanges user token${C_RESET}\n"
  format_token "$response" "intermediate" || true
  echo ""
  printf "${C_DIM}Phase 2: sandbox exchanges intermediate${C_RESET}\n"
  format_token "$response" "final"
else
  echo ""
  printf "${C_BOLD}Token inspection${C_RESET}\n"
  echo ""
  format_token "$response" "$PHASE"
fi
