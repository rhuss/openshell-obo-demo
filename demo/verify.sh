#!/usr/bin/env bash
# Non-interactive verification for the OBO demo (FR-005, SC-011).
# Never prompts. Asserts every beat's expected outcome.
#
# Usage:
#   verify.sh              Everything (requires ready environment)
#   verify.sh --unit       Unit tier only, no environment needed
#   verify.sh --no-inference  Skip inference-dependent evidence (SC-010)

set -euo pipefail

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demo/lib/common.sh
source "${VERIFY_DIR}/lib/common.sh"
# shellcheck source=demo/lib/beats.sh
source "${VERIFY_DIR}/lib/beats.sh"

MODE="full"
STRICT=false
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    --unit|--no-inference) MODE="$arg" ;;
    full|"") MODE="full" ;;
    *)
      echo "Usage: verify.sh [--unit | --no-inference] [--strict]" >&2
      exit 2
      ;;
  esac
done

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_TESTS=()
SKIPPED_TESTS=()

# ── Test helpers ────────────────────────────────────────────────────

assert_pass() {
  local name="$1"
  PASS_COUNT=$((PASS_COUNT + 1))
  printf "${C_GREEN}  PASS${C_RESET}  %s\n" "$name"
}

assert_fail() {
  local name="$1" reason="${2:-}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("$name")
  printf "${C_RED}  FAIL${C_RESET}  %s" "$name"
  [ -n "$reason" ] && printf " (%s)" "$reason"
  printf "\n"
}

# A test file that does not exist yet is NOT a pass. Counting absent tests as
# passes makes the harness incapable of failing, which is worse than having no
# harness: the subject-token lifetime test (T024) exists specifically to catch a
# regression from 5400s back to upstream's 1800s, and a green run would hide
# whether that test was ever written.
assert_skip() {
  local name="$1" reason="${2:-not yet implemented}"
  SKIP_COUNT=$((SKIP_COUNT + 1))
  SKIPPED_TESTS+=("$name ($reason)")
  printf "${C_YELLOW}  SKIP${C_RESET}  %s (%s)\n" "$name" "$reason"
}

# Run a test file if present, skip loudly if not.
run_test_file() {
  local name="$1" path="$2" runner="$3"
  if [ -f "$path" ]; then
    if "$runner" "$path" 2>&1; then
      assert_pass "$name"
    else
      assert_fail "$name" "$(basename "$path") failed"
    fi
  else
    assert_skip "$name" "$(basename "$path") not written"
  fi
}

# ── Unit tier ───────────────────────────────────────────────────────

run_unit_tests() {
  info "Unit tier: no infrastructure required"
  echo ""

  run_test_file "issuer-claims" "${VERIFY_DIR}/tests/test-issuer-claims.js" node
  run_test_file "mcp-protocol" "${VERIFY_DIR}/tests/test-mcp-protocol.js" node
  run_test_file "policy-valid" "${VERIFY_DIR}/tests/test-policy-valid.sh" bash
}

# ── End-to-end tier ─────────────────────────────────────────────────

run_e2e_tests() {
  local no_inference=false
  [ "$MODE" = "--no-inference" ] && no_inference=true

  info "End-to-end tier: requires ready environment"
  echo ""

  # ── Beat assertions: both paths (T061) ───────────────────────────

  local i
  for i in $(seq 1 "$BEAT_COUNT"); do
    load_beat "$i"

    printf "${C_DIM}  ---- beat %d: %s${C_RESET}\n" "$BEAT_ID" "$BEAT_CLAIM"

    # Skip inference-dependent beats when --no-inference
    if $no_inference && [ "$BEAT_NEEDS_INFERENCE" = "true" ]; then
      printf "${C_YELLOW}  SKIP${C_RESET}  beat %d (needs inference)\n" "$BEAT_ID"
      continue
    fi

    # Curl path (always tested)
    if eval "$BEAT_CURL_CMD" >/dev/null 2>&1; then
      if eval "$BEAT_ASSERT" 2>/dev/null; then
        assert_pass "beat-${BEAT_ID}-curl"
      else
        assert_fail "beat-${BEAT_ID}-curl" "assertion failed"
      fi
    else
      assert_fail "beat-${BEAT_ID}-curl" "command failed"
    fi

    # Agent path (full mode only, skip under --no-inference)
    if ! $no_inference; then
      if eval "$BEAT_AGENT_CMD" >/dev/null 2>&1; then
        if eval "$BEAT_ASSERT" 2>/dev/null; then
          assert_pass "beat-${BEAT_ID}-agent"
        else
          assert_fail "beat-${BEAT_ID}-agent" "assertion failed"
        fi
      else
        assert_fail "beat-${BEAT_ID}-agent" "command failed"
      fi
    fi

    # Custody evidence for beat 3 (T054a: independently skippable)
    if [ "$BEAT_ID" = "3" ] && [ -n "$BEAT_CUSTODY_EVIDENCE_CMD" ]; then
      if $no_inference && [ "$BEAT_CUSTODY_NEEDS_INFERENCE" = "true" ]; then
        printf "${C_YELLOW}  SKIP${C_RESET}  beat-3-custody (needs inference)\n"
      else
        if eval "$BEAT_CUSTODY_EVIDENCE_CMD" >/dev/null 2>&1; then
          assert_pass "beat-3-custody"
        else
          assert_fail "beat-3-custody" "custody evidence failed"
        fi
      fi
    fi
  done

  echo ""

  # ── Negative assertions (SC-008) ─────────────────────────────────

  info "Negative assertions"
  run_test_file "inspection-isolation" \
    "${VERIFY_DIR}/tests/test-inspection-isolation.sh" bash
  run_test_file "credential-custody" \
    "${VERIFY_DIR}/tests/test-credential-custody.sh" bash
  run_test_file "binary-denial" \
    "${VERIFY_DIR}/tests/test-binary-denial.sh" bash

  echo ""

  # ── Structural tests (SC-004, SC-010) ────────────────────────────

  info "Structural tests"
  run_test_file "beat-independence" \
    "${VERIFY_DIR}/tests/test-beat-independence.sh" bash
  run_test_file "path-equivalence" \
    "${VERIFY_DIR}/tests/test-path-equivalence.sh" bash
}

# ── Main ────────────────────────────────────────────────────────────

echo ""
printf "${C_BOLD}OBO Demo Verification${C_RESET}\n"
echo ""

case "$MODE" in
  --unit)
    run_unit_tests
    ;;
  --no-inference)
    run_unit_tests
    echo ""
    run_e2e_tests
    ;;
  full|"")
    run_unit_tests
    echo ""
    run_e2e_tests
    ;;
esac

# ── Summary ─────────────────────────────────────────────────────────

echo ""
if [ "$FAIL_COUNT" -gt 0 ]; then
  printf "${C_RED}${C_BOLD}%d failed${C_RESET}, %d passed, %d skipped\n" \
    "$FAIL_COUNT" "$PASS_COUNT" "$SKIP_COUNT"
  for t in "${FAILED_TESTS[@]}"; do
    printf "${C_RED}  FAILED:${C_RESET} %s\n" "$t"
  done
  exit 1
fi

if [ "$SKIP_COUNT" -gt 0 ]; then
  # Never claim success while tests are missing. During implementation this is
  # expected and exits 0 so the build loop is usable, but the count is always
  # stated so nobody reads an incomplete run as a complete one. Use --strict in
  # the final gate, where a skip is a defect.
  printf "${C_YELLOW}${C_BOLD}%d passed, %d skipped${C_RESET} (suite incomplete)\n" \
    "$PASS_COUNT" "$SKIP_COUNT"
  for t in "${SKIPPED_TESTS[@]}"; do
    printf "${C_YELLOW}  SKIPPED:${C_RESET} %s\n" "$t"
  done
  if $STRICT; then
    printf "${C_RED}strict mode: skipped tests are failures${C_RESET}\n"
    exit 1
  fi
  exit 0
fi

printf "${C_GREEN}${C_BOLD}All %d tests passed${C_RESET}\n" "$PASS_COUNT"
exit 0
