#!/usr/bin/env bash
# Stage runner for the OBO demo (FR-007, FR-008, FR-009, FR-010).
#
# Usage:
#   scene.sh              Run all beats in order, pausing between each
#   scene.sh <n>          Run beat n alone
#   scene.sh <n> --curl   Run beat n without the agent (curl path)
#   scene.sh --list       List beats with their claims
#
# Never creates or destroys the sandbox; bring-up.sh owns its lifecycle.

set -euo pipefail

SCENE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demo/lib/common.sh
source "${SCENE_DIR}/lib/common.sh"
# shellcheck source=demo/lib/beats.sh
source "${SCENE_DIR}/lib/beats.sh"

# ── Argument parsing ───────────────────────────────────────────────

BEAT_NUM=""
USE_CURL=false
LIST_MODE=false

for arg in "$@"; do
  case "$arg" in
    --list)  LIST_MODE=true ;;
    --curl)  USE_CURL=true ;;
    [1-9])   BEAT_NUM="$arg" ;;
    *)
      echo "Usage: scene.sh [<beat>] [--curl] | scene.sh --list" >&2
      exit 2
      ;;
  esac
done

# ── List mode ──────────────────────────────────────────────────────

if $LIST_MODE; then
  echo ""
  printf "${C_BOLD}Demo Beats${C_RESET}\n"
  echo ""
  list_beats
  echo ""
  exit 0
fi

# ── Helpers ────────────────────────────────────────────────────────

# Print a command before running it (FR-008)
show_and_run() {
  local label="$1"
  shift
  echo ""
  printf "${C_DIM}$ %s${C_RESET}\n" "$label"
  "$@"
}

# Wait for keypress between beats (FR-009)
wait_for_keypress() {
  if [ -t 0 ]; then
    echo ""
    printf "${C_DIM}Press any key to continue...${C_RESET}"
    read -rsn1
    echo ""
  fi
}

# Run a single beat with failure isolation (T060).
# Reports and returns control. Never aborts the session or unwinds prior beats.
run_beat() {
  local n="$1"
  local curl_path="$2"

  load_beat "$n"

  echo ""
  printf "${C_BOLD}━━━ Beat %d: %s ━━━${C_RESET}\n" "$BEAT_ID" "$BEAT_CLAIM"

  local cmd_func cmd_label
  if $curl_path; then
    cmd_func="$BEAT_CURL_CMD"
    cmd_label="curl path"
  else
    cmd_func="$BEAT_AGENT_CMD"
    cmd_label="agent path"
  fi

  # Run the command with failure isolation
  local beat_rc=0
  show_and_run "$cmd_label" "$cmd_func" || beat_rc=$?

  if [ "$beat_rc" -ne 0 ]; then
    echo ""
    printf "${C_YELLOW}Beat %d returned exit code %d. Continuing.${C_RESET}\n" \
      "$BEAT_ID" "$beat_rc"
  fi

  # Show evidence
  echo ""
  printf "${C_BOLD}Evidence:${C_RESET}\n"
  eval "$BEAT_EVIDENCE_CMD" 2>/dev/null || true

  # Show custody evidence for beat 3 if available and not --curl
  if [ "$BEAT_ID" = "3" ] && [ -n "$BEAT_CUSTODY_EVIDENCE_CMD" ] && ! $curl_path; then
    eval "$BEAT_CUSTODY_EVIDENCE_CMD" 2>/dev/null || true
  fi

  # Run the assertion silently to report pass/fail
  if eval "$BEAT_ASSERT" 2>/dev/null; then
    printf "\n${C_GREEN}PASS${C_RESET}  beat %d\n" "$BEAT_ID"
  else
    printf "\n${C_RED}FAIL${C_RESET}  beat %d (assertion did not hold)\n" "$BEAT_ID"
  fi
}

# ── Single beat mode ───────────────────────────────────────────────

if [ -n "$BEAT_NUM" ]; then
  if [ "$BEAT_NUM" -lt 1 ] || [ "$BEAT_NUM" -gt "$BEAT_COUNT" ]; then
    fail "Beat $BEAT_NUM does not exist. Valid range: 1-$BEAT_COUNT"
    exit 1
  fi
  run_beat "$BEAT_NUM" "$USE_CURL"
  exit 0
fi

# ── All beats mode ─────────────────────────────────────────────────

echo ""
printf "${C_BOLD}OBO Demo: Running all %d beats${C_RESET}\n" "$BEAT_COUNT"

for i in $(seq 1 "$BEAT_COUNT"); do
  run_beat "$i" "$USE_CURL"

  # Wait for keypress between beats, not after the last one
  if [ "$i" -lt "$BEAT_COUNT" ]; then
    wait_for_keypress
  fi
done

echo ""
printf "${C_BOLD}All beats complete.${C_RESET}\n"
