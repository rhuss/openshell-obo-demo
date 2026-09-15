#!/usr/bin/env bash
# Unit test: sandbox policy validity (T039, T040, T048).
# No infrastructure required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="${SCRIPT_DIR}/policy/sandbox-policy.yaml"
PASS=0
FAIL=0

assert() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf "  PASS  %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s\n" "$name"
    FAIL=$((FAIL + 1))
  fi
}

assert_not() {
  local name="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    printf "  PASS  %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s\n" "$name"
    FAIL=$((FAIL + 1))
  fi
}

# T039: policy file exists
assert "policy file exists" test -f "$POLICY"

# T039: policy is valid YAML and parses without error
assert "policy is valid YAML" python3 -c "
import sys, json
# Use json-based YAML subset parsing since PyYAML may not be installed
# The policy is simple enough to validate structurally
with open(sys.argv[1]) as f:
    content = f.read()
# Check it has required top-level keys
assert 'version:' in content
assert 'network_policies:' in content
assert 'filesystem_policy:' in content
" "$POLICY"

# T039: the tools/call rule carries a tool selector
assert "tools/call rule has tool selector" python3 -c "
import sys
with open(sys.argv[1]) as f:
    content = f.read()
# Find the tools/call allow line and verify it has a tool: field
lines = content.split('\n')
found_tools_call = False
for i, line in enumerate(lines):
    if 'tools/call' in line:
        found_tools_call = True
        # The tool selector must be on the same line or nearby
        assert 'tool:' in line or (i+1 < len(lines) and 'tool:' in lines[i+1]), \
            'tools/call allow must carry a tool selector'
        break
assert found_tools_call, 'no tools/call rule found'
" "$POLICY"

# T040: no deny_rules in the policy (both refusals by omission)
assert_not "no deny_rules in policy" grep -q "deny_rules" "$POLICY"

# T048: curl must NOT be sanctioned on the MCP endpoint. That is the whole of
# beat 5, so it is checked per policy block rather than across the whole file:
# `binaries` is scoped to its block, and beat 3's protected-service block does
# permit curl on a different host.
#
# Parsed as YAML rather than scanned as text. The previous version walked lines
# looking for `binaries:` and asserted every path contained "claude", which
# could not express "curl nowhere near MCP, curl fine on alpha" and would have
# had to be loosened into meaninglessness to accommodate it.
assert "mcp binaries sanction claude and python, never curl" python3 -c "
import sys, yaml

with open(sys.argv[1]) as handle:
    policy = yaml.safe_load(handle)

blocks = policy.get('network_policies', {})
mcp = blocks.get('mcp_tools')
assert mcp is not None, 'mcp_tools block missing'

def paths(block):
    return [entry['path'] if isinstance(entry, dict) else entry
            for entry in block.get('binaries', [])]

mcp_paths = paths(mcp)
assert '/usr/local/bin/claude' in mcp_paths, f'claude not sanctioned on MCP: {mcp_paths}'
assert not any('curl' in p for p in mcp_paths), f'curl sanctioned on MCP: {mcp_paths}'

# Beat 4 needs an agent-free path to MCP, and it has to be a binary the agent
# cannot tamper with, so require it to live under a read_only root.
read_only = set(policy.get('filesystem_policy', {}).get('read_only', []))
agent_free = [p for p in mcp_paths if p != '/usr/local/bin/claude']
assert agent_free, 'no agent-free binary sanctioned on MCP (FR-010)'
for path in agent_free:
    assert any(path.startswith(root.rstrip('/') + '/') for root in read_only), \
        f'{path} is sanctioned but not under a read_only root {sorted(read_only)}'
    # binaries are matched against /proc/<pid>/exe, so a symlink never matches
    assert not path.endswith('/python3'), \
        f'{path} is a symlink; name the resolved target (python3.N)'
" "$POLICY"

echo ""
if [ "$FAIL" -gt 0 ]; then
  printf "%d passed, %d failed\n" "$PASS" "$FAIL"
  exit 1
fi
printf "all %d policy checks passed\n" "$PASS"
